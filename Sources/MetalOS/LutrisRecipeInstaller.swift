import SwiftUI

@MainActor
final class LutrisRecipeInstaller: ObservableObject {
    struct InputRequest: Identifiable {
        let id = UUID()
        let title: String
        let isDirectory: Bool
        let extensions: Set<String>
    }

    @Published private(set) var status = "Preparing Lutris recipe…"
    @Published private(set) var isWorking = false
    @Published private(set) var inputRequest: InputRequest?
    private var inputContinuation: CheckedContinuation<URL?, Never>?

    func provideInput(_ url: URL?) {
        inputRequest = nil
        inputContinuation?.resume(returning: url)
        inputContinuation = nil
    }

    func install(profile: LutrisWineProfile, workspace: URL) async throws -> URL {
        guard !isWorking else { throw StudioError.message("A Lutris recipe is already running.") }
        guard let wine = WindowsRuntimeLayout.wineExecutable(in: workspace) else {
            throw StudioError.message("Install the managed Windows graphics runtime first in Settings → Windows Gaming.")
        }
        isWorking = true
        defer { isWorking = false }
        let manager = FileManager.default
        let bottles = WindowsRuntimeLayout.bottles(in: workspace)
        try manager.createDirectory(at: bottles, withIntermediateDirectories: true)
        let safeName = profile.gameName.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safeName.isEmpty ? "Windows Game" : safeName
        var bottleName = baseName, suffix = 2
        while manager.fileExists(atPath: bottles.appendingPathComponent(bottleName).path) {
            bottleName = "\(baseName) (\(suffix))"; suffix += 1
        }
        let bottle = bottles.appendingPathComponent(bottleName, isDirectory: true)
        let prefix = bottle.appendingPathComponent("prefix", isDirectory: true)
        try manager.createDirectory(at: prefix, withIntermediateDirectories: true)

        status = "Creating a \(profile.architecture) bottle…"
        _ = try await run(wine, ["wineboot", "-u", "-r"], prefix: prefix, cwd: bottle, profile: profile)
        if !profile.winetricks.isEmpty {
            guard let winetricks = WindowsRuntimeLayout.winetricksExecutable(in: workspace) else {
                throw StudioError.message("This recipe needs Winetricks (\(profile.winetricks.joined(separator: ", "))), but it is not installed.")
            }
            status = "Installing recipe dependencies…"
            _ = try await run(winetricks, ["-q"] + profile.winetricks, prefix: prefix, cwd: bottle, profile: profile, wineBinary: wine)
        }
        for (executable, version) in profile.wineAppVersionOverrides {
            status = "Applying \(executable) compatibility settings…"
            _ = try await run(wine, ["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\\(executable)",
                                     "/v", "Version", "/t", "REG_SZ", "/d", version, "/f"],
                              prefix: prefix, cwd: bottle, profile: profile)
        }
        try await applyOverrides(profile.overrides, wine: wine, prefix: prefix, cwd: bottle, profile: profile)
        status = "Bottle ready. Install your game, mods, and patches when you’re ready."
        return bottle
    }

    private func materialize(_ source: LutrisFileSource, into prefix: URL) async throws -> URL {
        let sourceIDParts = source.id.split(separator: ".")
        let sourceURL = URL(string: source.source)
        let fallbackExtension = sourceIDParts.count > 1
            ? String(sourceIDParts.last!)
            : (sourceURL?.pathExtension.isEmpty == false ? sourceURL?.pathExtension : nil)
        let expectedName = sourceURL?.lastPathComponent.isEmpty == false ? sourceURL?.lastPathComponent : nil
        status = "Select the Lutris file for \(source.id)…"
        guard let selected = await requestInput(
            title: "Select file for \(source.id)\(expectedName.map { " · \($0)" } ?? "")",
            directory: false,
            extensions: fallbackExtension.map { Set([$0]) } ?? []
        ), FileManager.default.isReadableFile(atPath: selected.path) else {
            throw StudioError.message("Select the local file for Lutris recipe entry \(source.id) to continue.")
        }
        // Keep selected installers and patches inside the Wine C: drive. Some Wine
        // builds cannot launch PE files selected from arbitrary macOS/external paths.
        let installFiles = prefix.appendingPathComponent("drive_c/MetalOS/LutrisFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: installFiles, withIntermediateDirectories: true)
        let safeID = source.id.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
        let ext = selected.pathExtension.isEmpty ? (fallbackExtension ?? "") : selected.pathExtension
        let destination = installFiles.appendingPathComponent(safeID.isEmpty ? UUID().uuidString : safeID)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        if selected.standardizedFileURL == destination.standardizedFileURL { return destination }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        do {
            try FileManager.default.copyItem(at: selected, to: destination)
        } catch {
            throw StudioError.message("Could not copy the selected Lutris file into the Wine bottle: \(error.localizedDescription)")
        }
        return destination
    }

    private func runTask(_ task: [String: LutrisJSONValue], profile: LutrisWineProfile, wine: URL, workspace: URL, prefix: URL, bottle: URL, cache: URL, files: [String: URL], disc: URL?) async throws {
        let name = task["name"]?.stringValue ?? ""
        let taskPrefix = task["prefix"]?.stringValue.map {
            URL(fileURLWithPath: expand($0, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)).standardizedFileURL
        } ?? prefix
        let taskArchitecture = task["arch"]?.stringValue ?? profile.architecture
        let taskEnvironment = task["env"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        let acceptedCode: Int? = {
            guard let raw = task["return_code"]?.stringValue, let parsed = Int(raw), parsed != 0 else { return nil }
            return parsed % 256 == 0 ? parsed / 256 : parsed
        }()
        switch name {
        case "create_prefix": return
        case "winekill":
            let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: wineserver.path) {
                _ = try await run(wineserver, ["-k"], prefix: taskPrefix, cwd: bottle, profile: profile, architecture: taskArchitecture)
            }
            return
        case "wineexec":
            guard let raw = task["executable"]?.stringValue else { throw StudioError.message("Lutris wineexec step has no executable.") }
            let exe = expand(raw, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)
            let args = LutrisWineProfile.arguments(from: task["args"]?.stringValue ?? "").map {
                expand($0, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)
            }
            status = "Running \(URL(fileURLWithPath: exe).lastPathComponent)…"
            let workingDirectory: URL
            if let rawWorkingDirectory = task["working_dir"]?.stringValue {
                let requested = URL(fileURLWithPath: expand(rawWorkingDirectory, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)).standardizedFileURL
                workingDirectory = Self.isDirectory(requested) ? requested : prefix
            } else if let configured = profile.workingDirectory {
                let requested = profile.resolveScriptPath(configured, prefix: prefix)
                workingDirectory = Self.isDirectory(requested) ? requested : Self.installerDirectory(exe, fallback: prefix)
            } else {
                // For setup executables running from mounted media, relative files
                // such as AutorunGUI.DLL are resolved from the executable's folder.
                workingDirectory = Self.installerDirectory(exe, fallback: prefix)
            }
            do {
                _ = try await run(wine, [exe] + args, prefix: taskPrefix, cwd: workingDirectory, profile: profile,
                                   architecture: taskArchitecture, environment: taskEnvironment, acceptedReturnCode: acceptedCode)
            } catch {
                throw StudioError.message("Wine could not start Lutris installer or patch ‘\(URL(fileURLWithPath: exe).lastPathComponent)’ from \(exe): \(error.localizedDescription)")
            }
        case "winetricks":
            guard let app = task["app"]?.stringValue,
                  let executable = WindowsRuntimeLayout.winetricksExecutable(in: workspace) else {
                throw StudioError.message("This Lutris step needs Winetricks, which is not installed.")
            }
            _ = try await run(executable, ["-q"] + app.split(whereSeparator: { $0.isWhitespace }).map(String.init), prefix: taskPrefix, cwd: bottle, profile: profile, wineBinary: wine, architecture: taskArchitecture, environment: taskEnvironment, acceptedReturnCode: acceptedCode)
        case "set_regedit":
            guard let rawPath = task["path"]?.stringValue,
                  let key = task["key"]?.stringValue,
                  let value = task["value"]?.stringValue else {
                throw StudioError.message("Lutris set_regedit needs path, key, and value.")
            }
            let registryPath = rawPath
                .replacingOccurrences(of: "HKEY_CURRENT_USER", with: "HKCU")
                .replacingOccurrences(of: "HKEY_LOCAL_MACHINE", with: "HKLM")
                .replacingOccurrences(of: "HKEY_CLASSES_ROOT", with: "HKCR")
                .replacingOccurrences(of: "HKEY_USERS", with: "HKU")
                .replacingOccurrences(of: "HKEY_CURRENT_CONFIG", with: "HKCC")
            var arguments = ["reg", "add", registryPath, "/v", key, "/d", value, "/f"]
            if let type = task["type"]?.stringValue { arguments += ["/t", type] }
            _ = try await run(wine, arguments, prefix: taskPrefix, cwd: bottle, profile: profile, architecture: taskArchitecture, environment: taskEnvironment, acceptedReturnCode: acceptedCode)
        case "set_regedit_file":
            guard let rawFile = task["filename"]?.stringValue else { throw StudioError.message("Lutris set_regedit_file needs a filename.") }
            let file = expand(rawFile, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)
            _ = try await run(wine, ["regedit", file], prefix: taskPrefix, cwd: bottle, profile: profile, architecture: taskArchitecture, environment: taskEnvironment, acceptedReturnCode: acceptedCode)
        default: throw StudioError.message("MetalOS does not support the Lutris task ‘\(name)’ yet.")
        }
    }

    private func runFileOperation(_ name: String, value: LutrisJSONValue, profile: LutrisWineProfile, prefix: URL, bottle: URL, cache: URL, files: [String: URL], disc: URL?) async throws {
        let values = value.objectValue ?? [:]
        func path(_ key: String) throws -> URL {
            let rawValue: String?
            if key == "src" {
                rawValue = values["src"]?.stringValue ?? (name == "extract" ? values["file"]?.stringValue : nil)
            } else if key == "file" {
                rawValue = values["file"]?.stringValue ?? values["src"]?.stringValue
            } else if key == "dst" {
                rawValue = values["dst"]?.stringValue ?? (name == "extract" ? prefix.path : nil)
            } else {
                rawValue = values[key]?.stringValue
            }
            let scalarPath = value.stringValue
            let selectedValue = rawValue ?? (["mkdir", "chmod", "chmodx"].contains(name) ? scalarPath : nil)
            guard let raw = selectedValue else { throw StudioError.message("Lutris \(name) step is missing \(key).") }
            return URL(fileURLWithPath: expand(raw, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)).standardizedFileURL
        }
        let manager = FileManager.default
        switch name {
        case "mkdir": try manager.createDirectory(at: path("dst"), withIntermediateDirectories: true)
        case "copy", "move", "merge":
            let src = try path("src"), dst = try path("dst")
            try manager.createDirectory(at: dst, withIntermediateDirectories: true)
            guard manager.fileExists(atPath: src.path) else {
                if values["optional"]?.stringValue == "true" { return }
                throw StudioError.message("Lutris \(name) source does not exist: \(src.path)")
            }
            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: src.path, isDirectory: &isDirectory)
            if isDirectory.boolValue && name != "move" {
                try mergeDirectoryContents(src, to: dst)
            } else {
                try manager.createDirectory(at: dst, withIntermediateDirectories: true)
                let target = dst.appendingPathComponent(src.lastPathComponent)
                try mergeItem(src, to: target, move: name == "move")
            }
            if values["remove_source"]?.stringValue == "true", name == "merge" { try? manager.removeItem(at: src) }
        case "extract":
            let src = try path("src"), dst = try path("dst")
            try manager.createDirectory(at: dst, withIntermediateDirectories: true)
            try await extractArchive(src, to: dst, format: values["format"]?.stringValue, mergeSingle: values["nomerge"]?.stringValue != "true")
        case "chmod", "chmodx":
            let target = try path("file")
            let current = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            try manager.setAttributes([.posixPermissions: current | 0o111], ofItemAtPath: target.path)
        default: break
        }
    }

    private func mergeItem(_ source: URL, to destination: URL, move: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        if move { try manager.moveItem(at: source, to: destination) }
        else { try manager.copyItem(at: source, to: destination) }
    }

    private func mergeDirectoryContents(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            var targetIsDirectory: ObjCBool = false
            let targetExists = manager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
            if values?.isDirectory == true && targetExists && targetIsDirectory.boolValue {
                try mergeDirectoryContents(item, to: target)
            } else {
                if targetExists { try manager.removeItem(at: target) }
                try manager.copyItem(at: item, to: target)
            }
        }
    }

    private func extractArchive(_ archive: URL, to destination: URL, format: String?, mergeSingle: Bool) async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: archive.path) else {
            throw StudioError.message("Lutris archive file was not found: \(archive.path)")
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".lutris-extract-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let archiveName = archive.lastPathComponent.lowercased()
        let kind = (format ?? archive.pathExtension).lowercased()
        if ["zip", "auto"].contains(kind) || (format == nil && archiveName.hasSuffix(".zip")) {
            _ = try await Self.runProcess(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, staging.path])
        } else if ["tar", "tgz", "txz", "tbz", "tbz2", "tzst", "gz", "xz", "bz2", "zst"].contains(kind)
                    && (kind == "tar" || ["tgz", "txz", "tbz", "tbz2", "tzst"].contains(kind) || archiveName.hasSuffix(".tar.\(kind)") || archiveName.hasSuffix(".tar.gz") || archiveName.hasSuffix(".tar.xz") || archiveName.hasSuffix(".tar.bz2") || archiveName.hasSuffix(".tar.zst")) {
            _ = try await Self.runProcess(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
        } else if kind == "gzip" || (format == nil && archiveName.hasSuffix(".gz") && !archiveName.hasSuffix(".tar.gz")) {
            try await Self.decompressGzip(archive, to: staging)
        } else {
            if kind == "gog" {
                guard let innoextract = Self.findExecutable(named: ["innoextract"]) else {
                    throw StudioError.message("This Lutris recipe needs Inno Setup extraction. Install innoextract for macOS, then retry.")
                }
                _ = try await Self.runProcess(innoextract, ["-m", "-g", "-d", staging.path, "-e", archive.path])
            } else {
                guard let sevenZip = Self.findExecutable(named: ["7zz", "7z", "7za"]) else {
                throw StudioError.message("This Lutris recipe needs a 7-Zip compatible extractor for \(archive.lastPathComponent). Install 7-Zip for macOS, then retry.")
                }
                _ = try await Self.runProcess(sevenZip, ["x", archive.path, "-o\(staging.path)", "-y"])
            }
        }
        let entries = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
        if mergeSingle, entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try mergeDirectoryContents(entries[0], to: destination)
        } else {
            try mergeDirectoryContents(staging, to: destination)
        }
    }

    private func applyOverrides(_ values: [String: String], wine: URL, prefix: URL, cwd: URL, profile: LutrisWineProfile) async throws {
        for (key, value) in values {
            let dll = URL(fileURLWithPath: key).lastPathComponent
            guard dll.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { continue }
            let override = value.split(separator: ",").map { part -> String in
                switch part.trimmingCharacters(in: .whitespaces).lowercased() { case "n": "native"; case "b": "builtin"; default: String(part) }
            }.joined(separator: ",")
            _ = try await run(wine, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", dll, "/d", override, "/f"], prefix: prefix, cwd: cwd, profile: profile)
        }
    }

    private func runSafeExecute(_ values: [String: LutrisJSONValue], profile: LutrisWineProfile, prefix: URL, bottle: URL) throws {
        guard let command = values["command"]?.stringValue else {
            throw StudioError.message("This Lutris recipe has an execute step without a command.")
        }
        let parts = LutrisWineProfile.arguments(from: command)
        guard parts.first == "chmod", parts.count >= 3 else {
            throw StudioError.message("This Lutris recipe contains a custom shell command MetalOS will not run.")
        }
        var index = 1
        let recursive = parts[index] == "-R"
        if recursive { index += 1 }
        guard index < parts.count, parts[index] == "+w" else {
            throw StudioError.message("MetalOS only supports Lutris chmod +w setup commands.")
        }
        index += 1
        let root = bottle.standardizedFileURL.path + "/"
        for raw in parts[index...] {
            let resolved = profile.expand(raw, prefix: prefix).replacingOccurrences(of: "$GAMEDIR", with: bottle.path)
            let target = URL(fileURLWithPath: resolved).standardizedFileURL
            guard target.path == bottle.path || target.path.hasPrefix(root),
                  FileManager.default.fileExists(atPath: target.path) else {
                throw StudioError.message("A Lutris chmod step points outside its new bottle, so MetalOS stopped the recipe.")
            }
            let targets: [URL]
            if recursive {
                targets = ([target] + (FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []))
            } else {
                targets = [target]
            }
            for item in targets {
                let current = (try? FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                try FileManager.default.setAttributes([.posixPermissions: current | 0o200], ofItemAtPath: item.path)
            }
        }
    }

    private func runHostExecute(_ values: [String: LutrisJSONValue], profile: LutrisWineProfile, prefix: URL, bottle: URL, cache: URL, files: [String: URL], disc: URL?) async throws -> String {
        guard let rawFile = values["file"]?.stringValue else {
            throw StudioError.message("Lutris execute needs a file. Shell commands are limited to safe file permission changes on macOS.")
        }
        let expanded = expand(rawFile, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)
        let executable: URL
        if let file = files[rawFile] {
            executable = file
        } else if expanded.contains("/") {
            executable = URL(fileURLWithPath: expanded)
        } else if let found = Self.findExecutable(named: [expanded]) {
            executable = found
        } else {
            throw StudioError.message("The Lutris recipe requires the native macOS tool ‘\(expanded)’, but it is not installed.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StudioError.message("The Lutris execute file is not a runnable macOS tool: \(executable.path)")
        }
        let args = LutrisWineProfile.arguments(from: values["args"]?.stringValue ?? "").map {
            expand($0, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc)
        }
        let workingDirectory = values["working_dir"]?.stringValue.map {
            URL(fileURLWithPath: expand($0, profile: profile, prefix: prefix, bottle: bottle, cache: cache, files: files, disc: disc))
        }.flatMap { Self.isDirectory($0) ? $0 : nil } ?? bottle
        return try await Self.runProcess(executable, args, directory: workingDirectory)
    }

    private func expand(_ raw: String, profile: LutrisWineProfile, prefix: URL, bottle: URL, cache: URL, files: [String: URL], disc: URL?) -> String {
        if let file = files[raw] { return file.path }
        var value = profile.expand(raw, prefix: prefix)
        value = value.replacingOccurrences(of: "$GAMEDIR", with: bottle.path).replacingOccurrences(of: "$CACHE", with: cache.path).replacingOccurrences(of: "$DISC", with: disc?.path ?? "")
        for (key, url) in files.sorted(by: { $0.key.count > $1.key.count }) {
            value = value.replacingOccurrences(of: "$\(key)", with: url.path).replacingOccurrences(of: "${\(key)}", with: url.path)
        }
        return value
    }

    private func requestInput(title: String, directory: Bool, extensions: Set<String>) async -> URL? {
        await withCheckedContinuation { continuation in
            inputContinuation = continuation
            inputRequest = InputRequest(title: title, isDirectory: directory, extensions: extensions)
        }
    }

    private func run(_ executable: URL, _ args: [String], prefix: URL, cwd: URL, profile: LutrisWineProfile,
                     wineBinary: URL? = nil, architecture: String? = nil,
                     environment overrides: [String: String] = [:], acceptedReturnCode: Int? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix.path; env["WINEARCH"] = architecture ?? profile.architecture; env["WINEDEBUG"] = "-all"
            for (key, value) in profile.environment { env[key] = value }
            for (key, value) in overrides { env[key] = value }
            if let wineBinary { env["WINE"] = wineBinary.path }
            WindowsRuntimeLayout.configureGamepadEnvironment(&env)
            process.environment = env; process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = pipe
            try AppProcessSupervisor.run(process); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let accepted = acceptedReturnCode.map { process.terminationStatus == $0 } ?? false
            guard process.terminationStatus == 0 || accepted else {
                throw StudioError.message(String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func runProcess(_ executable: URL, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe(); process.executableURL = executable; process.arguments = args
            process.standardOutput = pipe; process.standardError = pipe
            try AppProcessSupervisor.run(process); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw StudioError.message(String(decoding: data.suffix(4000), as: UTF8.self)) }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func findExecutable(named names: [String]) -> URL? {
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for name in names {
            for directory in searchPaths {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func installerDirectory(_ executable: String, fallback: URL) -> URL {
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().standardizedFileURL
        return isDirectory(directory) ? directory : fallback
    }

    private nonisolated static func runProcess(_ executable: URL, _ args: [String], directory: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = args
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            try AppProcessSupervisor.run(process)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func decompressGzip(_ archive: URL, to destination: URL) async throws {
        let outputURL = destination.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let file = try? FileHandle(forWritingTo: outputURL) else {
            throw StudioError.message("Could not create the extracted file for \(archive.lastPathComponent).")
        }
        defer { try? file.close() }
        try await Task.detached(priority: .utility) {
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", archive.path]
            process.standardOutput = file
            process.standardError = errors
            try AppProcessSupervisor.run(process)
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }
}

struct LutrisRecipeInstallPage: View {
    let profile: LutrisWineProfile
    let workspace: URL
    let onComplete: (URL) -> Void
    @Environment(\.consolePageClose) private var closePage
    @StateObject private var installer = LutrisRecipeInstaller()
    @State private var error: String?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("LUTRIS RECIPE").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(studioAccent)
            Text("Prepare \(profile.gameName)").font(.system(size: 27, weight: .light))
            Text("\(profile.installerVersion) · \(profile.architecture.uppercased()) · \(profile.winetricks.count) dependencies · \(profile.overrides.count) DLL overrides").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if installer.isWorking { ProgressView().controlSize(.small).tint(studioAccent) }
                Text(error ?? installer.status).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if !installer.isWorking {
                HStack(spacing: 12) {
                    Button("Start recipe") { start() }.buttonStyle(.borderedProminent).tint(studioAccent).disabled(started)
                    Button("Close") { closePage() }.buttonStyle(.bordered)
                }
            }
            Spacer()
            Text("MetalOS prepares the Wine bottle from this Lutris profile. You choose and install the game, mods, and patches yourself.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBackground.ignoresSafeArea()).preferredColorScheme(.dark).tint(studioAccent)
        .consolePage(isPresented: Binding(get: { installer.inputRequest != nil }, set: { if !$0 { installer.provideInput(nil) } })) {
            if let request = installer.inputRequest {
                ConsoleFilePicker(title: request.title, mode: request.isDirectory ? .directory : .file,
                                  startingPath: request.isDirectory ? "/Volumes" : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path,
                                  allowedExtensions: request.extensions) { installer.provideInput($0) }
            }
        }
        .consoleInput { command in if (command == "back" || command == "menu") && !installer.isWorking { closePage() } }
    }

    private func start() {
        guard !started else { return }; started = true
        Task {
            do { let executable = try await installer.install(profile: profile, workspace: workspace); onComplete(executable) }
            catch { self.error = error.localizedDescription }
        }
    }
}
