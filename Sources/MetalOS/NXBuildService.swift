import Foundation
import Combine
import Darwin

struct NXBuildPlan {
    let executable: URL
    let workingDirectory: URL
    let arguments: [String]
    let outputApp: URL
    let workDirectory: URL
    let logFile: URL

    /// Creates an argument vector; game titles, spaces and shell characters are never interpreted.
    static func make(game: Game, settings: LauncherSettings, buildsRoot: URL? = nil) throws -> NXBuildPlan {
        let fm = FileManager.default
        let fork = (game.forkPath?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? settings.forkPath
        guard !fork.isEmpty else { throw StudioError.message("Choose your NXNative fork checkout in Settings, or set a checkout for this title.") }
        let checkout = URL(fileURLWithPath: (fork as NSString).expandingTildeInPath).standardizedFileURL
        let script = checkout.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        guard fm.isReadableFile(atPath: script.path) else { throw StudioError.message("The selected checkout does not contain scripts/build_ipa_from_nsp.py.") }
        let python = URL(fileURLWithPath: (settings.pythonPath as NSString).expandingTildeInPath)
        guard fm.isExecutableFile(atPath: python.path) else { throw StudioError.message("Choose an executable Python 3.12 or newer interpreter in Settings.") }
        guard let inputPath = game.buildInput, !inputPath.isEmpty else { throw StudioError.message("Import a game folder before starting an NXNative build.") }
        let input = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath).standardizedFileURL
        guard fm.fileExists(atPath: input.path) else { throw StudioError.message("The game input is unavailable. Reconnect its drive or select the game folder again.") }
        // The game owns its extraction/build workspace, including across rescans.
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: input.path, isDirectory: &isDirectory)
        let gameFolder = isDirectory.boolValue ? input : input.deletingLastPathComponent()
        let workspace = gameFolder.appendingPathComponent("NXNative", isDirectory: true)
        let work = workspace.appendingPathComponent("Work", isDirectory: true)
        let outputDirectory = workspace.appendingPathComponent("Build", isDirectory: true)
        // NXNative's mac platform builds the host and game files in place, then prints a
        // direct launch command. It does not package a Mac application bundle.
        let outputTarget = outputDirectory.appendingPathComponent("Build result", isDirectory: true)
        var args = [script.path, input.path, "--platform", "mac", "--work-dir", work.path]
        if game.source == .nxnative, let icon = game.boxArt?.path, fm.isReadableFile(atPath: icon) {
            args += ["--fallback-icon", icon]
        }
        if !settings.keysPath.isEmpty {
            let keys = (settings.keysPath as NSString).expandingTildeInPath
            guard fm.isReadableFile(atPath: keys) else { throw StudioError.message("The configured prod.keys file is unavailable.") }
            args += ["-k", keys]
        }
        return NXBuildPlan(executable: python, workingDirectory: checkout, arguments: args, outputApp: outputTarget, workDirectory: work, logFile: outputDirectory.appendingPathComponent("build.log"))
    }

    static func runConfiguration(from logURL: URL, workDirectory: URL) throws -> GameRunConfiguration {
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let lines = log.components(separatedBy: .newlines)
        guard let marker = lines.lastIndex(where: { $0.contains("done: the game runs on the Mac with this command") }),
              let command = lines.dropFirst(marker + 1).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StudioError.message("NXNative finished without a Mac launch command. Open the build log for details.")
        }
        let words = try shellWords(command)
        guard words.count > 4, words[0] == "cd", words[2] == "&&" else {
            throw StudioError.message("NXNative returned an unrecognized Mac launch command.")
        }
        let cwd = URL(fileURLWithPath: words[1]).standardizedFileURL
        let base = workDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard cwd.path.hasPrefix(base + "/") else { throw StudioError.message("NXNative's launch folder is outside this game's workspace.") }
        var environment: [String: String] = [:]
        var index = 3
        while index < words.count, let separator = words[index].firstIndex(of: "="), separator != words[index].startIndex {
            let key = String(words[index][..<separator])
            let value = String(words[index][words[index].index(after: separator)...])
            guard key.hasPrefix("DM_") else { throw StudioError.message("NXNative returned an unsafe launch setting.") }
            environment[key] = value
            index += 1
        }
        guard index < words.count else { throw StudioError.message("NXNative did not specify a game executable.") }
        let executable = URL(fileURLWithPath: words[index]).standardizedFileURL
        guard executable.path.hasPrefix(base + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StudioError.message("NXNative's game host is missing from this game's workspace.")
        }
        let arguments = Array(words.dropFirst(index + 1))
        guard arguments.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw StudioError.message("NXNative returned an invalid game argument.")
        }
        return GameRunConfiguration(executablePath: executable.path, arguments: arguments, environment: environment, workingDirectory: cwd.path)
    }

    private static func shellWords(_ command: String) throws -> [String] {
        enum Quote: Equatable { case none, single, double }
        var quote = Quote.none
        var escaped = false
        var word = ""
        var words: [String] = []
        var hasWord = false
        for character in command {
            if escaped { word.append(character); escaped = false; hasWord = true; continue }
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { word.append(character) }
                hasWord = true
            case .double:
                if character == "\\" { escaped = true }
                else if character == "\"" { quote = .none }
                else { word.append(character) }
                hasWord = true
            case .none:
                if character == "\\" { escaped = true; hasWord = true }
                else if character == "'" { quote = .single; hasWord = true }
                else if character == "\"" { quote = .double; hasWord = true }
                else if character.isWhitespace {
                    if hasWord { words.append(word); word = ""; hasWord = false }
                } else { word.append(character); hasWord = true }
            }
        }
        guard !escaped, quote == .none else { throw StudioError.message("NXNative returned an incomplete Mac launch command.") }
        if hasWord { words.append(word) }
        return words
    }

}

@MainActor
final class NXBuildService: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var log = ""
    @Published private(set) var status = "Ready to build"
    @Published private(set) var outputApp: URL?
    @Published private(set) var logFile: URL?
    @Published private(set) var currentGameID: String?
    @Published private(set) var progress: Double?
    @Published private(set) var progressDetail = "Preparing build…"
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var toastMessage: String?
    @Published private(set) var activePhase = "Preparing build"
    var elapsedLabel: String {
        let total = max(0, Int(elapsedSeconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }
    private(set) var profileRevisionUsed: String?
    private var activeGameTitle = "Game"
    private var buildStartedAt: Date?
    var onComplete: ((String, URL) -> Void)?
    var onRunReady: ((String, GameRunConfiguration) -> Void)?
    private var process: Process?
    private var timer: Timer?
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var cancelled = false
    private var activePlan: NXBuildPlan?
    private let buildsRoot: URL?

    init(buildsRoot: URL? = nil) {
        self.buildsRoot = buildsRoot
    }

    func start(game: Game, settings: LauncherSettings) {
        guard !isBuilding else { return }
        outputApp = nil
        log = ""
        cancelled = false
        currentGameID = game.id
        activeGameTitle = game.title
        profileRevisionUsed = game.nxSupport?.latestProfileRevision
        progress = nil
        progressDetail = "Preparing build…"
        elapsedSeconds = 0
        buildStartedAt = Date()
        do {
            let plan = try NXBuildPlan.make(game: game, settings: settings, buildsRoot: buildsRoot)
            try FileManager.default.createDirectory(at: plan.workDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plan.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: plan.logFile.path, contents: nil)
            let output = try FileHandle(forWritingTo: plan.logFile)
            writer = output
            reader = try FileHandle(forReadingFrom: plan.logFile)
            logFile = plan.logFile
            activePlan = plan
            let task = Process()
            task.executableURL = plan.executable
            task.currentDirectoryURL = plan.workingDirectory
            // A new session gives cancellation a scoped process group. The upstream SIGTERM
            // handler also cleans its own tool groups. No shell is used.
            task.arguments = ["-u", "-c", "import os, sys; os.setsid() if os.getpgrp() != os.getpid() else None; os.execv(sys.executable, [sys.executable, '-u'] + sys.argv[1:])"] + plan.arguments
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            task.environment = env
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = output
            task.standardError = output
            task.terminationHandler = { [weak self] terminated in
                Task { @MainActor in self?.finish(exitCode: terminated.terminationStatus) }
            }
            process = task
            try task.run()
            isBuilding = true
            status = "Building \(game.title)…"
            progressDetail = "Starting NXNative…"
            activePhase = "Starting NXNative"
            postToast("Building \(game.title)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshBuildState() }
            }
        } catch {
            cleanup()
            status = "Build could not start"
            progressDetail = error.localizedDescription
            log = error.localizedDescription
            postToast("Build could not start: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let process, process.isRunning, !cancelled else { return }
        cancelled = true
        status = "Stopping build…"
        progressDetail = "Stopping build…"
        // NXNative handles SIGTERM and stops its tool process groups itself.
        // Signal the isolated group as well, for forks without that handler.
        if Darwin.kill(-process.processIdentifier, SIGTERM) != 0 { process.terminate() }
    }

    private func refreshLog() {
        guard let data = try? reader?.readToEnd(), !data.isEmpty else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        log += chunk
        updateProgress(from: chunk)
        if log.count > 180_000 { log = String(log.suffix(150_000)) }
    }

    private func refreshBuildState() {
        refreshLog()
        if let buildStartedAt { elapsedSeconds = Date().timeIntervalSince(buildStartedAt) }
    }

    private func finish(exitCode: Int32) {
        refreshLog()
        if cancelled {
            status = "Build cancelled"
            progressDetail = "Build cancelled"
            postToast("Build cancelled")
        }
        else if exitCode != 0 {
            status = "Build failed (exit \(exitCode)). See the log below."
            progressDetail = "Build failed · exit \(exitCode)"
            postToast("Build failed. Open the build log for details.")
        }
        else if let plan = activePlan {
            do {
                let configuration = try NXBuildPlan.runConfiguration(from: plan.logFile, workDirectory: plan.workDirectory)
                status = "Build complete · Ready to play"
                progress = 1
                progressDetail = "Build complete"
                activePhase = "Build complete"
                postToast("\(currentGameTitle) is ready to play")
                if let gameID = currentGameID { onRunReady?(gameID, configuration) }
            } catch {
                status = "Build finished, but the game could not be prepared to run."
                progressDetail = error.localizedDescription
                postToast("Could not prepare \(currentGameTitle) to play")
            }
        }
        cleanup()
    }

    private var currentGameTitle: String {
        activeGameTitle
    }

    private func updateProgress(from text: String) {
        let clean = text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let latestLine = lines.last else { return }
        progressDetail = String(latestLine.suffix(110))
        activePhase = String(latestLine.suffix(60))
        let percentagePattern = try! NSRegularExpression(pattern: #"(?<![0-9])([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#)
        // A single file read can contain several lines or carriage-return progress updates.
        // Keep the newest percentage anywhere in that chunk instead of only checking its last line.
        for line in lines {
            let nsLine = line as NSString
            let matches = percentagePattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                guard match.numberOfRanges > 1, let value = Double(nsLine.substring(with: match.range(at: 1))), (0...100).contains(value) else { continue }
                progress = value / 100
            }
        }
    }

    private func postToast(_ message: String) {
        toastMessage = message
    }

    func dismissToast() { toastMessage = nil }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        try? writer?.close()
        try? reader?.close()
        writer = nil
        reader = nil
        process = nil
        activePlan = nil
        isBuilding = false
    }
}
