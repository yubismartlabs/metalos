import SwiftUI
import AppKit

@MainActor
private final class WindowsBottleTools: ObservableObject {
    @Published private(set) var status = "Choose an action for this game's private Windows bottle."
    @Published private(set) var isWorking = false

    func report(_ message: String) { status = message }

    func add(_ source: URL, to game: Game, prefix: URL, asFolder: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        status = "Copying into this game's bottle…"
        defer { isWorking = false }
        do {
            let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey])
            guard sourceValues.isDirectory == asFolder else {
                throw StudioError.message(asFolder ? "Choose a folder." : "Choose a file.")
            }
            let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
            try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
            let preferred = game.windowsExecutablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                ?? (game.isAvailable ? URL(fileURLWithPath: game.installPath, isDirectory: true) : nil)
            let destinationDirectory = preferred.flatMap { candidate -> URL? in
                let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
                return resolved.path.hasPrefix(driveC.standardizedFileURL.resolvingSymlinksInPath().path + "/") ? resolved : nil
            } ?? driveC.appendingPathComponent("MetalOS Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destination = Self.uniqueDestination(source.lastPathComponent, in: destinationDirectory)
            try FileManager.default.copyItem(at: source, to: destination)
            status = "Added \(source.lastPathComponent) to \(destinationDirectory.lastPathComponent)."
        } catch {
            status = "Could not add that item: \(error.localizedDescription)"
        }
    }

    func install(_ installer: URL, game: Game, workspace: URL, prefix: URL) async {
        guard !isWorking else { return }
        guard ["exe", "msi"].contains(installer.pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: installer.path) else {
            status = "Choose a readable Windows .exe or .msi installer."
            return
        }
        let runtime = game.windowsCompatibilityRuntime ?? .managedWine
        let wine = runtime == .gamePortingToolkit
            ? WindowsRuntimeLayout.gamePortingToolkitWineExecutable(in: workspace)
            : WindowsRuntimeLayout.wineExecutable(in: workspace)
        guard let wine else {
            status = runtime == .gamePortingToolkit
                ? "Install Game Porting Toolkit in Settings → Windows Gaming first."
                : "Install the Windows graphics runtime in Settings → Windows Gaming first."
            return
        }
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else {
            status = "This game's Windows bottle is not ready yet. Launch the game once, then try again."
            return
        }
        isWorking = true
        status = "Running \(installer.lastPathComponent) in \(game.title)'s bottle…"
        defer { isWorking = false }
        do {
            let args = installer.pathExtension.lowercased() == "msi"
                ? ["msiexec", "/i", installer.path]
                : [installer.path]
            let workingDirectory = installer.deletingLastPathComponent()
            if let profile = game.lutrisWineProfile {
                for (executable, version) in profile.wineAppVersionOverrides {
                    _ = try await Self.run(wine,
                                           arguments: ["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\\(executable)",
                                                       "/v", "Version", "/t", "REG_SZ", "/d", version, "/f"],
                                           prefix: prefix, workingDirectory: workingDirectory, profile: profile)
                }
            }
            let result = try await Self.run(wine, arguments: args, prefix: prefix, workingDirectory: workingDirectory,
                                           profile: game.lutrisWineProfile)
            let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: wineserver.path) {
                status = "Waiting for the bottle installer to finish…"
                _ = try await Self.run(wineserver, arguments: ["-w"], prefix: prefix, workingDirectory: workingDirectory)
            }
            status = result.isEmpty
                ? "Wine exited successfully (code 0). Check the game before installing another patch."
                : String(result.suffix(700))
        } catch {
            status = "Could not run the installer: \(error.localizedDescription)"
        }
    }

    private static func uniqueDestination(_ name: String, in directory: URL) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var number = 2
        repeat {
            candidate = directory.appendingPathComponent("\(base) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        } while manager.fileExists(atPath: candidate.path)
        return candidate
    }

    private nonisolated static func run(_ executable: URL, arguments: [String], prefix: URL, workingDirectory: URL,
                                        profile: LutrisWineProfile? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix.path
            environment["WINEDEBUG"] = "-all"
            if let profile {
                for (key, value) in profile.environment where !["WINE", "WINEPREFIX", "WINEARCH"].contains(key.uppercased()) {
                    environment[key] = profile.expand(value, prefix: prefix)
                }
                if !profile.overrides.isEmpty { environment["WINEDLLOVERRIDES"] = profile.wineDLLOverrides }
                environment["WINEPREFIX"] = prefix.path
                environment["WINEARCH"] = profile.architecture
            }
            WindowsRuntimeLayout.configureGamepadEnvironment(&environment)
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let diagnostic = String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw StudioError.message(diagnostic.isEmpty ? "Wine exited with code \(process.terminationStatus) and returned no diagnostic output." : diagnostic)
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

struct WindowsBottleToolsView: View {
    let game: Game
    let workspace: URL
    let onClose: () -> Void
    @StateObject private var tools = WindowsBottleTools()
    @State private var picker: PickerPurpose?
    @State private var selection = 0

    private enum PickerPurpose { case patch, file, folder }
    private var prefix: URL? {
        if let provider = game.windowsStoreProvider, let id = game.windowsStoreGameID {
            return WindowsRuntimeLayout.storePrefix(provider: provider, gameID: id, in: workspace)
        }
        guard let path = game.windowsBottlePath else { return nil }
        let bottle = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return WindowsRuntimeLayout.winePrefix(forBottleAt: bottle)
    }
    private var separateBottleDrive: URL? {
        guard game.windowsStoreProvider == nil, let path = game.windowsBottlePath else { return nil }
        let bottle = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let activePrefix = WindowsRuntimeLayout.winePrefix(forBottleAt: bottle)
        let duplicate = bottle.appendingPathComponent("drive_c", isDirectory: true)
        return activePrefix != bottle && FileManager.default.fileExists(atPath: duplicate.path) ? duplicate : nil
    }
    private var actions: [(String, String, String)] {
        [(game.windowsExecutablePath == nil ? "Install game, patch, or runtime" : "Install a patch or runtime", "Run a manually selected .exe or .msi inside this game's bottle.", "wrench.and.screwdriver"),
         ("Add a file", "Copy a file beside the game executable.", "doc.badge.plus"),
         ("Add a folder", "Copy a folder beside the game executable.", "folder.badge.plus"),
         ("Open bottle files", "Browse this game's Windows C: drive in Finder.", "folder")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.system(size: 22)).foregroundStyle(studioAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game bottle").font(.system(size: 26, weight: .light))
                    Text(game.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").padding(9).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close bottle tools")
            }
            if let prefix {
                Text("Active Wine prefix · \(prefix.path)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2).textSelection(.enabled)
            }
            if let separateBottleDrive, let prefix {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("A separate C: drive was left by an earlier patch run. This game and new patches use the existing prefix at \(prefix.path). The extra drive at \(separateBottleDrive.path) is not used.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
                }.padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 9) {
                ForEach(actions.indices, id: \.self) { index in
                    Button { selection = index; perform(index) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: actions[index].2).font(.system(size: 18)).frame(width: 28).foregroundStyle(studioAccent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(actions[index].0).font(.system(size: 13, weight: .medium))
                                Text(actions[index].1).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(selection == index ? 0.24 : 0.08)))
                    }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selection == index, cornerRadius: 12, scale: 1.02)
                        .disabled(tools.isWorking)
                }
            }
            if tools.isWorking { ProgressView().controlSize(.small).tint(studioAccent) }
            ScrollView {
                Text(tools.status).font(.system(size: 11)).foregroundStyle(tools.status.hasPrefix("Could not") ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 110)
            Text("↑ ↓  Choose     A / ×  Select     B / ○  Back").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(24).frame(width: 620).background(studioBackground).preferredColorScheme(.dark).tint(studioAccent)
        .consoleInput { command in
            switch command {
            case "up", "left": selection = max(0, selection - 1)
            case "down", "right": selection = min(actions.count - 1, selection + 1)
            case "confirm": perform(selection)
            case "back", "menu", "context": if !tools.isWorking { onClose() }
            default: break
            }
        }
        .consolePage(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if let picker {
                let directory = prefix?.appendingPathComponent("drive_c", isDirectory: true).path
                ConsoleFilePicker(title: picker == .patch ? "Choose a Windows patch or runtime" : picker == .file ? "Choose a file to add to the game" : "Choose a folder to add to the game",
                                  mode: picker == .folder ? .directory : .file,
                                  startingPath: picker == .patch ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path : directory,
                                  allowedExtensions: picker == .patch ? ["exe", "msi"] : []) { url in
                    let purpose = self.picker
                    self.picker = nil
                    guard let prefix else { tools.report("This game's bottle could not be found."); return }
                    Task {
                        if purpose == .patch { await tools.install(url, game: game, workspace: workspace, prefix: prefix) }
                        else { await tools.add(url, to: game, prefix: prefix, asFolder: purpose == .folder) }
                    }
                }
            }
        }
    }

    private func perform(_ index: Int) {
        guard !tools.isWorking else { return }
        switch index {
        case 0: picker = .patch
        case 1: picker = .file
        case 2: picker = .folder
        case 3:
            guard let prefix else { tools.report("This game's bottle could not be found."); return }
            let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
            guard FileManager.default.fileExists(atPath: driveC.path) else { tools.report("This game's bottle is not ready yet. Launch the game once, then try again."); return }
            NSWorkspace.shared.open(driveC)
            tools.report("Opened this game's C: drive in Finder.")
        default: break
        }
    }
}
