import Foundation
import Combine
import CryptoKit
import Darwin
import AppKit

struct WindowsWineRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let digest: String?
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, size, digest; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let htmlURL: URL
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case htmlURL = "html_url"; case assets }
}

enum WindowsRuntimeLayout {
    /// SDL's GameController/MFi backend can claim generic HID pads without exposing
    /// usable controls to Wine games on recent macOS releases. Prefer SDL's IOKit path.
    static func configureGamepadEnvironment(_ environment: inout [String: String]) {
        environment["SDL_JOYSTICK_MFI"] = "0"
    }

    static func setMetalSharpGameEnvironment(_ values: [String: String], removing keysToRemove: [String] = [], in gameDirectory: URL) throws {
        let manager = FileManager.default
        let configDirectory = gameDirectory.appendingPathComponent(".metalsharp", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("launch.local.env")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var managedKeys = Set(keysToRemove.map { $0.uppercased() })
        managedKeys.formUnion(values.keys.map { $0.uppercased() })
        var lines = existing.components(separatedBy: .newlines).filter { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.first.map { !managedKeys.contains($0.trimmingCharacters(in: .whitespaces).uppercased()) } ?? true
        }
        lines.append(contentsOf: values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else {
            if manager.fileExists(atPath: configURL.path) { try manager.removeItem(at: configURL) }
            return
        }
        try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    static func root(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".nxstudio/Engines/WindowsGaming", isDirectory: true)
    }
    static func wine(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Wine", isDirectory: true)
    }
    static func gamePortingToolkit(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Game Porting Toolkit.app", isDirectory: true)
    }
    static func gamePortingToolkitWine(in workspace: URL) -> URL {
        gamePortingToolkit(in: workspace).appendingPathComponent("Contents/Resources/wine/bin/wine64")
    }
    static func gamePortingToolkitWineExecutable(in workspace: URL) -> URL? {
        let manager = FileManager.default
        let managed = gamePortingToolkitWine(in: workspace)
        if manager.isExecutableFile(atPath: managed.path) { return managed }
        let candidates = [
            URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64")
        ]
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
    static func bottles(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Bottles", isDirectory: true)
    }
    static func highballHome(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("HighballData", isDirectory: true)
    }
    static func highballRepository(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Tools/highball", isDirectory: true)
    }
    static func highballCLI(in workspace: URL) -> URL {
        highballRepository(in: workspace).appendingPathComponent(".build/release/highball")
    }
    static func legendaryCLI(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Tools/legendary/legendary")
    }
    static func gogdlCLI(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Tools/heroic-gogdl/.venv/bin/gogdl")
    }
    static func gogAuth(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("GOG/auth.json")
    }
    static func bottle(_ name: String, in workspace: URL) -> URL {
        bottles(in: workspace).appendingPathComponent(name, isDirectory: true)
    }
    static func winePrefix(forBottleAt bottle: URL) -> URL {
        let resolvedBottle = bottle.standardizedFileURL
        let nestedPrefix = resolvedBottle.appendingPathComponent("prefix", isDirectory: true)
        return FileManager.default.fileExists(atPath: nestedPrefix.appendingPathComponent("drive_c").path)
            ? nestedPrefix : resolvedBottle
    }
    static func storePrefix(provider: String, gameID: String, in workspace: URL) -> URL {
        let key = SHA256.hash(data: Data("\(provider):\(gameID)".utf8)).map { String(format: "%02x", $0) }.joined()
        return root(in: workspace).appendingPathComponent("Prefixes/\(provider)-\(key)", isDirectory: true)
    }
    static func wineExecutable(in workspace: URL) -> URL? {
        let base = wine(in: workspace)
        let candidates = [
            "MetalSharp-Wine.app/Contents/MacOS/wine",
            "MetalSharp-Wine-x86_64.app/Contents/MacOS/wine",
            "bin/wine64", "bin/wine", "wine.app/Contents/Resources/wine/bin/wine64"
        ]
        if let direct = candidates.map({ base.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return direct }
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) else { return nil }
        while let file = enumerator.nextObject() as? URL {
            if ["wine64", "wine"].contains(file.lastPathComponent), file.pathComponents.contains("bin"),
               (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true { return file }
        }
        return nil
    }
    static func winetricksExecutable(in workspace: URL) -> URL? {
        let manager = FileManager.default
        let runtimeRoot = wine(in: workspace)
        let candidates = [
            runtimeRoot.appendingPathComponent("bin/winetricks"),
            runtimeRoot.appendingPathComponent("winetricks"),
            URL(fileURLWithPath: "/opt/homebrew/bin/winetricks"),
            URL(fileURLWithPath: "/usr/local/bin/winetricks"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/winetricks")
        ]
        if let bundled = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) { return bundled }
        for directory in ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("winetricks")
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private struct HighballLibraryListing: Decodable, Sendable {
    let id: String
    let title: String
    let source: String
    let environment: String?
    let installed: Bool
    let installedOnMac: Bool
}

enum HighballLibraryDiscovery {
    static func scan(workspace: URL) async -> [Game] {
        let cli = WindowsRuntimeLayout.highballCLI(in: workspace)
        let repository = WindowsRuntimeLayout.highballRepository(in: workspace)
        let home = WindowsRuntimeLayout.highballHome(in: workspace)
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path) else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = cli
            process.arguments = ["library", "--json"]
            process.currentDirectoryURL = repository
            var environment = ProcessInfo.processInfo.environment
            environment["HIGHBALL_HOME"] = home.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try AppProcessSupervisor.run(process)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let entries = try JSONDecoder().decode([HighballLibraryListing].self, from: data)
                return entries.compactMap { entry -> Game? in
                    guard entry.installed, let bottleName = entry.environment, !bottleName.isEmpty else { return nil }
                    let source: GameSource
                    switch entry.source {
                    case "steam": source = .steam
                    case "pin": source = .windows
                    default: return nil
                    }
                    let id = entry.id.hasPrefix("steam:") ? entry.id : "highball:\(entry.id)"
                    let bottle = home.appendingPathComponent("bottles/\(bottleName)", isDirectory: true)
                    return Game(id: id, title: entry.title, source: source, launchURL: "metalos-highball://library",
                                installPath: bottle.path, highballLibraryID: entry.id, highballBottleName: bottleName)
                }
            } catch { return [] }
        }.value
    }
}

enum StorefrontLibraryDiscovery {
    private struct EpicInstalledGame: Decodable {
        let appName: String
        let title: String
        let installPath: String
        let isDLC: Bool?
        enum CodingKeys: String, CodingKey { case appName = "app_name", title, installPath = "install_path", isDLC = "is_dlc" }
    }

    static func scan(workspace: URL) async -> [Game] {
        var games = await epicGames(workspace: workspace)
        games += gogGames(workspace: workspace)
        return games
    }

    private static func epicGames(workspace: URL) async -> [Game] {
        let cli = WindowsRuntimeLayout.legendaryCLI(in: workspace)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return [] }
        do {
            let output = try await run(cli, ["list-installed", "--json", "--show-dirs"])
            let entries = try JSONDecoder().decode([EpicInstalledGame].self, from: Data(output.utf8))
            return entries.compactMap { entry in
                guard entry.isDLC != true, FileManager.default.fileExists(atPath: entry.installPath) else { return nil }
                return Game(id: "legendary:\(entry.appName)", title: entry.title, source: .epic,
                            launchURL: "metalos-store://epic/\(entry.appName)", installPath: entry.installPath,
                            windowsStoreProvider: "epic", windowsStoreGameID: entry.appName)
            }
        } catch { return [] }
    }

    private static func gogGames(workspace: URL) -> [Game] {
        let root = WindowsRuntimeLayout.highballHome(in: workspace)
            .appendingPathComponent("bottles/MetalOS-GOG/drive_c/Program Files/MetalOS/GOG", isDirectory: true)
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let infoFiles = folders.flatMap { folder -> [URL] in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let children = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
            return children.filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }
        }
        return infoFiles.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["rootGameId"] as? Int else { return nil }
            let title = object["name"] as? String ?? file.deletingLastPathComponent().lastPathComponent
            let path = file.deletingLastPathComponent().path
            return Game(id: "gog:\(id)", title: title, source: .gog,
                        launchURL: "metalos-store://gog/\(id)", installPath: path,
                        windowsStoreProvider: "gog", windowsStoreGameID: String(id))
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try AppProcessSupervisor.run(process); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw StudioError.message("Legendary could not read the installed game list.") }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

@MainActor
final class WindowsWineInstaller: ObservableObject {
    @Published private(set) var status = "Wine is not installed."
    @Published private(set) var isWorking = false
    @Published private(set) var installedVersion: String?
    @Published private(set) var runtimeName = "Windows graphics runtime"
    @Published private(set) var progress: Double?

    func refresh(workspace: URL?) {
        guard let workspace else { status = "Choose a library folder first."; return }
        if let version = readVersion(in: workspace), WindowsRuntimeLayout.wineExecutable(in: workspace) != nil {
            installedVersion = version
            runtimeName = readRuntimeName(in: workspace)
            status = "\(runtimeName) \(version) is installed in your library folder."
        } else {
            installedVersion = nil
            status = "Install the Wine runtime in your library folder."
        }
    }

    func install(workspace: URL?) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Complete library setup before installing the Windows runtime."; return }
        guard ProcessInfo.processInfo.machineArchitecture == "arm64" else {
            status = "The managed Windows gaming runtime currently requires Apple silicon."
            return
        }
        isWorking = true
        progress = nil
        defer { isWorking = false; progress = nil }
        let root = WindowsRuntimeLayout.root(in: workspace)
        let destination = WindowsRuntimeLayout.wine(in: workspace)
        let staging = root.appendingPathComponent("Wine-install-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("windows-graphics-runtime.archive")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let useMetalSharpWine = osVersion.majorVersion >= 15
        let supportsNative32BitWindows = osVersion.majorVersion > 26 || (osVersion.majorVersion == 26 && osVersion.minorVersion >= 4)
        let useRosettaBuild = useMetalSharpWine && !supportsNative32BitWindows
        let runtimeLabel = useRosettaBuild ? "MetalSharp Wine (Rosetta 2)" : useMetalSharpWine ? "MetalSharp Wine" : "Wine Staging"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if useRosettaBuild {
                do {
                    _ = try await run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"])
                } catch {
                    throw StudioError.message("This macOS version needs Rosetta 2 for 32-bit Windows installer support. Install Rosetta, then update the Windows graphics runtime.")
                }
            }
            status = "Checking the latest \(runtimeLabel) release…"
            let repository = useMetalSharpWine ? "metalsharp/MetalSharp-Wine" : "Gcenx/macOS_Wine_builds"
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.setValue("MetalOS Windows runtime installer", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("GitHub did not return the Wine release information.") }
            let release = try JSONDecoder().decode(WindowsWineRelease.self, from: data)
            if readVersion(in: workspace) == release.tagName, readRuntimeName(in: workspace) == runtimeLabel,
               WindowsRuntimeLayout.wineExecutable(in: workspace) != nil {
                status = "\(runtimeLabel) \(release.tagName) is already up to date."
                return
            }
            let releaseVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            let asset = release.assets.first(where: { asset in
                if useMetalSharpWine {
                    let architecture = useRosettaBuild ? "x86_64" : "arm64"
                    return asset.name == "MetalSharp-Wine-\(releaseVersion)-\(architecture).zip"
                }
                return asset.name.hasPrefix("wine-staging-") && asset.name.hasSuffix("-osx64.tar.xz")
            })
            guard let asset,
                  asset.size > 0, asset.size < 1_500_000_000,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else {
                throw StudioError.message("The latest \(runtimeLabel) release has no supported macOS archive and SHA-256 checksum.")
            }
            status = "Downloading \(runtimeLabel) \(release.tagName)…"
            var downloadRequest = URLRequest(url: asset.browserDownloadURL)
            downloadRequest.setValue("MetalOS Windows runtime installer", forHTTPHeaderField: "User-Agent")
            let (temporary, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
            guard let http = downloadResponse as? HTTPURLResponse, http.statusCode == 200 else {
                throw StudioError.message("The Wine archive could not be downloaded.")
            }
            try FileManager.default.moveItem(at: temporary, to: archive)
            let actual = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst("sha256:".count)).lowercased() else {
                throw StudioError.message("The downloaded Wine archive did not match its published SHA-256 checksum.")
            }
            status = "Verifying the graphics runtime archive…"
            let listTool = URL(fileURLWithPath: useMetalSharpWine ? "/usr/bin/unzip" : "/usr/bin/tar")
            let listArguments = useMetalSharpWine ? ["-Z1", archive.path] : ["-tf", archive.path]
            let listing = try await run(listTool, listArguments)
            let paths = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard !paths.isEmpty, paths.count < 500_000,
                  paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                throw StudioError.message("The graphics runtime archive contains an invalid file path.")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            status = "Extracting \(runtimeLabel) \(release.tagName)…"
            if useMetalSharpWine {
                _ = try await run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", archive.path, "-d", staging.path])
            } else {
                _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
            }
            let candidates = useMetalSharpWine
                ? [useRosettaBuild ? "MetalSharp-Wine-x86_64.app/Contents/MacOS/wine" : "MetalSharp-Wine.app/Contents/MacOS/wine"]
                : ["bin/wine64", "bin/wine", "wine.app/Contents/Resources/wine/bin/wine64"]
            guard candidates.map({ staging.appendingPathComponent($0) }).contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) || Self.findWine(in: staging) != nil else {
                throw StudioError.message("The graphics runtime archive did not contain a supported Wine executable.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("Wine-backup-\(Int(Date().timeIntervalSince1970))"))
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            let marker = root.appendingPathComponent("wine-version.txt")
            try "\(release.tagName)\n\(release.htmlURL.absoluteString)\n".write(to: marker, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: archive)
            installedVersion = release.tagName
            runtimeName = runtimeLabel
            status = useMetalSharpWine
                ? "\(runtimeLabel) \(release.tagName) is ready. The signed runtime includes Mullion (DXMT), DXVK-MacOS, VKD3D-Proton, and MoltenVK."
                : "\(runtimeLabel) \(release.tagName) is ready. This older macOS version does not support the newer MetalSharp Wine DirectX stack."
        } catch {
            status = "Wine installation failed: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }
    }

    private func readVersion(in workspace: URL) -> String? {
        let marker = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("wine-version.txt")
        return try? String(contentsOf: marker, encoding: .utf8).components(separatedBy: .newlines).first
    }

    private func readRuntimeName(in workspace: URL) -> String {
        let wineRoot = WindowsRuntimeLayout.wine(in: workspace)
        if FileManager.default.fileExists(atPath: wineRoot.appendingPathComponent("MetalSharp-Wine-x86_64.app").path) {
            return "MetalSharp Wine (Rosetta 2)"
        }
        if FileManager.default.fileExists(atPath: wineRoot.appendingPathComponent("MetalSharp-Wine.app").path) {
            return "MetalSharp Wine"
        }
        let marker = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("wine-version.txt")
        let lines = (try? String(contentsOf: marker, encoding: .utf8).components(separatedBy: .newlines)) ?? []
        if lines.dropFirst().first?.contains("metalsharp/MetalSharp-Wine") == true {
            return "MetalSharp Wine (legacy package; update recommended)"
        }
        return "Wine Staging"
    }

    private nonisolated static func findWine(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) else { return nil }
        while let file = enumerator.nextObject() as? URL {
            if ["wine64", "wine"].contains(file.lastPathComponent), file.pathComponents.contains("bin"),
               (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true { return file }
        }
        return nil
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

@MainActor
final class GamePortingToolkitInstaller: ObservableObject {
    @Published private(set) var status = "Install Gcenx’s Game Porting Toolkit for an Apple D3DMetal runtime option."
    @Published private(set) var installedVersion: String?
    @Published private(set) var isWorking = false
    @Published private(set) var runtimeURL: URL?

    func refresh(workspace: URL?) {
        guard let workspace else {
            runtimeURL = nil
            installedVersion = nil
            status = "Choose a library folder before managing Game Porting Toolkit."
            return
        }
        runtimeURL = WindowsRuntimeLayout.gamePortingToolkitWineExecutable(in: workspace)
        guard let runtimeURL else {
            installedVersion = nil
            status = "Game Porting Toolkit is not installed."
            return
        }
        let marker = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("gptk-version.txt")
        let markerLines = (try? String(contentsOf: marker, encoding: .utf8).components(separatedBy: .newlines)) ?? []
        let isManaged = runtimeURL.path.hasPrefix(WindowsRuntimeLayout.root(in: workspace).path + "/")
        let version = isManaged ? markerLines.first : Self.bundleVersion(for: runtimeURL)
        installedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? version : "Installed"
        status = isManaged
            ? "Gcenx Game Porting Toolkit \(installedVersion ?? "") is managed in the library folder."
            : "Using the system Game Porting Toolkit at \(runtimeURL.path)."
    }

    func install(workspace: URL?) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        #if !arch(arm64)
        status = "Game Porting Toolkit runs on Apple Silicon Macs only."
        return
        #else
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 else {
            status = "Game Porting Toolkit requires macOS 14 Sonoma or newer."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let root = WindowsRuntimeLayout.root(in: workspace)
        let destination = WindowsRuntimeLayout.gamePortingToolkit(in: workspace)
        let archive = root.appendingPathComponent("gptk-download.tar.xz")
        let staging = root.appendingPathComponent(".gptk-staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            status = "Checking the latest Gcenx Game Porting Toolkit release…"
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Gcenx/game-porting-toolkit/releases/latest")!)
            request.setValue("MetalOS Game Porting Toolkit manager", forHTTPHeaderField: "User-Agent")
            let (releaseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("GitHub did not return Game Porting Toolkit release information.") }
            let release = try JSONDecoder().decode(WindowsWineRelease.self, from: releaseData)
            let marker = root.appendingPathComponent("gptk-version.txt")
            if FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.gamePortingToolkitWine(in: workspace).path),
               (try? String(contentsOf: marker, encoding: .utf8).components(separatedBy: .newlines).first) == release.tagName {
                status = "Game Porting Toolkit \(release.tagName) is already up to date."
                return
            }
            let suffix = release.tagName.replacingOccurrences(of: "Game-Porting-Toolkit-", with: "")
            guard let asset = release.assets.first(where: { $0.name == "game-porting-toolkit-\(suffix).tar.xz" }),
                  asset.size > 0, asset.size < 1_500_000_000,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else {
                throw StudioError.message("The latest Game Porting Toolkit release has no supported archive and SHA-256 checksum.")
            }
            status = "Downloading Game Porting Toolkit \(release.tagName)…"
            var downloadRequest = URLRequest(url: asset.browserDownloadURL)
            downloadRequest.setValue("MetalOS Game Porting Toolkit manager", forHTTPHeaderField: "User-Agent")
            let (temporary, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("Game Porting Toolkit could not be downloaded.") }
            try FileManager.default.moveItem(at: temporary, to: archive)
            let actual = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst("sha256:".count)).lowercased() else {
                throw StudioError.message("The Game Porting Toolkit archive failed its published SHA-256 check.")
            }
            status = "Verifying the toolkit archive…"
            let listing = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
            let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard !entries.isEmpty, entries.count < 500_000,
                  entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                throw StudioError.message("The toolkit archive contains an invalid file path.")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            status = "Extracting the toolkit…"
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
            guard let bundle = Self.findToolkitBundle(in: staging),
                  FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/Resources/wine/bin/wine64").path) else {
                throw StudioError.message("The toolkit archive is missing its Game Porting Toolkit.app Wine executable.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                let backup = root.appendingPathComponent("Game-Porting-Toolkit-backup-\(Int(Date().timeIntervalSince1970)).app", isDirectory: true)
                try FileManager.default.moveItem(at: destination, to: backup)
            }
            try FileManager.default.moveItem(at: bundle, to: destination)
            status = "Preparing the toolkit for macOS…"
            _ = try? await Self.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-drs", "com.apple.quarantine", destination.path])
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--deep", "--sign", "-", destination.path])
            try "\(release.tagName)\n\(release.htmlURL.absoluteString)\n".write(to: root.appendingPathComponent("gptk-version.txt"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: archive)
            installedVersion = release.tagName
            runtimeURL = destination.appendingPathComponent("Contents/Resources/wine/bin/wine64")
            status = "Game Porting Toolkit \(release.tagName) is ready. Review Apple’s D3DMetal license in the release before use."
        } catch {
            status = "Game Porting Toolkit installation failed: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }
        #endif
    }

    private static func bundleVersion(for wineExecutable: URL) -> String? {
        let bundle = wineExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    private static func findToolkitBundle(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("Game Porting Toolkit.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "app", url.lastPathComponent == "Game Porting Toolkit.app" { return url }
        }
        return nil
    }

    private nonisolated static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

@MainActor
final class WindowsClientInstaller: ObservableObject {
    @Published private(set) var status = "Install a Windows game client to set up its managed bottle."
    @Published private(set) var isWorking = false

    func installSteam(workspace: URL?) async {
        await installHighballClient(name: "MetalOS-Steam", recipe: "steam", workspace: workspace, engine: .default)
    }

    func installRockstar(workspace: URL?) async {
        await installHighballClient(name: "MetalOS-Rockstar", recipe: "rockstar", workspace: workspace, engine: .rockstar)
    }

    func installStandaloneInstaller(at installer: URL, workspace: URL?, lutrisProfile: LutrisWineProfile? = nil) async -> String? {
        guard !isWorking else { return nil }
        guard let workspace else { status = "Choose a library folder first."; return nil }
        guard installer.pathExtension.lowercased() == "exe", FileManager.default.isReadableFile(atPath: installer.path) else {
            status = "Choose a readable Windows .exe installer."
            return nil
        }
        guard let wine = WindowsRuntimeLayout.wineExecutable(in: workspace) else {
            status = "Install the managed Windows graphics runtime first in Settings → Windows Gaming."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let bottles = WindowsRuntimeLayout.bottles(in: workspace)
            try FileManager.default.createDirectory(at: bottles, withIntermediateDirectories: true)
            let listing = ((try? FileManager.default.contentsOfDirectory(at: bottles, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .map { $0.lastPathComponent + "\t" }.joined(separator: "\n")
            let baseName = Self.standaloneBottleBase(for: installer)
            let bottleName = Self.uniqueBottleName(base: baseName, listing: listing)
            let bottle = bottles.appendingPathComponent(bottleName, isDirectory: true)
            let prefix = bottle.appendingPathComponent("prefix", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            status = "Preparing a clean Windows prefix…"
            _ = try await Self.runWine(wine, arguments: ["wineboot", "-u", "-r"], prefix: prefix,
                                       workingDirectory: installer.deletingLastPathComponent(), architecture: lutrisProfile?.architecture)
            let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: wineserver.path) {
                _ = try await Self.runWine(wineserver, arguments: ["-w"], prefix: prefix,
                                           workingDirectory: installer.deletingLastPathComponent(), architecture: lutrisProfile?.architecture)
            }
            if let lutrisProfile, !lutrisProfile.winetricks.isEmpty {
                guard let winetricks = WindowsRuntimeLayout.winetricksExecutable(in: workspace) else {
                    throw StudioError.message("This Lutris profile needs Winetricks (\(lutrisProfile.winetricks.joined(separator: ", "))), but no Winetricks executable was found. Install it with Homebrew, then try again.")
                }
                status = "Installing Lutris dependencies: \(lutrisProfile.winetricks.joined(separator: ", "))…"
                _ = try await Self.runWine(winetricks, arguments: ["-q"] + lutrisProfile.winetricks, prefix: prefix,
                                           workingDirectory: installer.deletingLastPathComponent(),
                                           architecture: lutrisProfile.architecture, wineBinary: wine)
            }
            if let lutrisProfile, !lutrisProfile.overrides.isEmpty {
                status = "Applying Lutris DLL overrides…"
                for (dll, value) in lutrisProfile.overrides.sorted(by: { $0.key < $1.key }) {
                    let safeDLL = URL(fileURLWithPath: dll).lastPathComponent
                    guard safeDLL.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { continue }
                    let override = Self.wineOverrideValue(value)
                    _ = try await Self.runWine(wine, arguments: ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", safeDLL, "/d", override, "/f"],
                                               prefix: prefix, workingDirectory: installer.deletingLastPathComponent(),
                                               architecture: lutrisProfile.architecture)
                }
            }
            status = "Opening the Windows installer in its managed Wine prefix…"
            _ = try await Self.runWine(wine, arguments: [installer.path], prefix: prefix,
                                       workingDirectory: installer.deletingLastPathComponent(), architecture: lutrisProfile?.architecture)
            status = "Installer closed. Select the installed game’s .exe to add it to the library."
            return bottleName
        } catch {
            status = "Could not run the Windows installer: \(error.localizedDescription)"
            return nil
        }
    }

    private enum HighballEngineChoice { case `default`, rockstar }

    private func installHighballClient(name: String, recipe: String, workspace: URL?, engine choice: HighballEngineChoice) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let setup = try await prepareHighballCLI(workspace: workspace)
            let manifest: URL?
            switch choice {
            case .default:
                manifest = setup.repository.appendingPathComponent("spike/engine-manifest.json")
            case .rockstar:
                manifest = Self.latestRockstarEngine(in: setup.repository)
            }
            guard let manifest, FileManager.default.fileExists(atPath: manifest.path) else {
                throw StudioError.message("Highball’s checkout has no manifest for the requested engine.")
            }
            let renderer: String? = { if case .rockstar = choice { return "dxmt" }; return nil }()
            try await ensureHighballBottle(name: name, recipe: recipe, manifest: manifest, renderer: renderer, setup: setup)
            status = recipe == "steam"
                ? "Steam bottle is ready. Open Windows Steam to sign in and install games."
                : "Rockstar bottle is ready. Open Rockstar Games Launcher to sign in and install games."
        } catch {
            status = "Could not prepare \(recipe.capitalized) through Highball CLI: \(error.localizedDescription)"
        }
    }

    private func ensureHighballBottle(name: String, recipe: String, manifest: URL, renderer: String?, setup: HighballSetup) async throws {
        let engineID = try await ensureHighballEngine(manifest: manifest, label: recipe.capitalized, setup: setup)
        let bottles = try await runCLI(setup.binary, ["bottle", "list"], repository: setup.repository, home: setup.home)
        let existing = bottles.split(separator: "\n").first { $0.hasPrefix(name + "\t") }
        if existing == nil {
            status = "Creating the \(recipe.capitalized) bottle and applying its recipe…"
            var args = ["bottle", "create", name, "--engine", engineID]
            if let renderer { args += ["--renderer", renderer] }
            args += ["--recipe", recipe]
            _ = try await runCLI(setup.binary, args, repository: setup.repository, home: setup.home)
        } else if existing?.contains("engine=\(engineID)") != true {
            status = "Updating the \(recipe.capitalized) bottle for its current engine…"
            _ = try await runCLI(setup.binary, ["bottle", "set", name, "engine", engineID], repository: setup.repository, home: setup.home)
            _ = try await runCLI(setup.binary, ["bottle", "repair", name], repository: setup.repository, home: setup.home)
        }
    }

    private func ensureHighballEngine(manifest: URL, label: String, setup: HighballSetup) async throws -> String {
        let engineID = try Self.engineID(from: manifest)
        status = "Checking Highball’s \(label) engine…"
        let installed = try await runCLI(setup.binary, ["engine", "list"], repository: setup.repository, home: setup.home)
        let complete = installed.split(separator: "\n").contains { $0.hasPrefix(engineID + "\t") && !$0.contains("INCOMPLETE") }
        if !complete {
            status = "Downloading and installing Highball’s \(label) engine…"
            _ = try await runCLI(setup.binary, ["engine", "install", manifest.path], repository: setup.repository, home: setup.home)
        }
        return engineID
    }

    private nonisolated static func standaloneBottleBase(for installer: URL) -> String {
        let raw = installer.deletingPathExtension().lastPathComponent
        let safe = raw.replacingOccurrences(of: "[^A-Za-z0-9 _.-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return "MetalOS-\(String((safe.isEmpty ? "Game" : safe).prefix(38)))"
    }

    private nonisolated static func uniqueBottleName(base: String, listing: String) -> String {
        let taken = Set(listing.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) })
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    func launchRockstar(workspace: URL?) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let setup = try await prepareHighballCLI(workspace: workspace, updateSource: false)
            guard let manifest = Self.latestRockstarEngine(in: setup.repository) else {
                throw StudioError.message("Highball’s checkout has no CrossOver-derived Wine 11 engine manifest.")
            }
            let bottleName = "MetalOS-Rockstar"
            try await ensureHighballBottle(name: bottleName, recipe: "rockstar", manifest: manifest, renderer: "dxmt", setup: setup)
            status = "Opening Rockstar Games Launcher…"
            _ = try await runCLI(setup.binary, ["run", bottleName, "Rockstar Launcher"], repository: setup.repository, home: setup.home)
            status = "Rockstar Games Launcher closed."
        } catch {
            status = "Could not open Rockstar Games Launcher: \(error.localizedDescription)"
        }
    }

    func launchSteam(workspace: URL?) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let setup = try await prepareHighballCLI(workspace: workspace, updateSource: false)
            let manifest = setup.repository.appendingPathComponent("spike/engine-manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw StudioError.message("Highball’s checkout has no default Wine engine manifest.")
            }
            let bottleName = "MetalOS-Steam"
            try await ensureHighballBottle(name: bottleName, recipe: "steam", manifest: manifest, renderer: nil, setup: setup)
            status = "Opening Windows Steam… Its first client update can take several minutes."
            _ = try await runCLI(setup.binary, ["run", bottleName, "Steam"], repository: setup.repository, home: setup.home)
            status = "Windows Steam closed."
        } catch {
            status = "Could not open Windows Steam: \(error.localizedDescription)"
        }
    }

    struct HighballSetup {
        let binary: URL
        let repository: URL
        let home: URL
    }

    func prepareHighballCLI(workspace: URL, updateSource: Bool = true) async throws -> HighballSetup {
        let tools = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Tools", isDirectory: true)
        let repository = WindowsRuntimeLayout.highballRepository(in: workspace)
        let database = tools.appendingPathComponent("highball-db", isDirectory: true)
        let highballPackage = repository.appendingPathComponent("Package.swift")
        let databaseMarker = database.appendingPathComponent("recipes/launchers/rockstar.json")
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        guard FileManager.default.isExecutableFile(atPath: git.path), FileManager.default.isExecutableFile(atPath: swift.path) else {
            throw StudioError.message("Highball CLI setup needs Apple’s Command Line Tools (git and Swift). Install them, then try again.")
        }
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let sourceExists = FileManager.default.fileExists(atPath: highballPackage.path)
        if !sourceExists {
            status = "Downloading Highball CLI source…"
            _ = try await Self.runTool(git, ["clone", "--depth", "1", "https://github.com/gauthierpiarrette/highball.git", repository.path], directory: tools)
        } else if updateSource {
            status = "Updating Highball CLI source…"
            _ = try await Self.runTool(git, ["-C", repository.path, "pull", "--ff-only"], directory: tools)
        }
        let databaseExists = FileManager.default.fileExists(atPath: databaseMarker.path)
        if !databaseExists {
            status = "Downloading Highball’s open recipes…"
            _ = try await Self.runTool(git, ["clone", "--depth", "1", "https://github.com/gauthierpiarrette/highball-db.git", database.path], directory: tools)
        } else if updateSource {
            _ = try await Self.runTool(git, ["-C", database.path, "pull", "--ff-only"], directory: tools)
        }
        let binary = repository.appendingPathComponent(".build/release/highball")
        if updateSource || !FileManager.default.isExecutableFile(atPath: binary.path) {
            status = "Building Highball CLI from source…"
            _ = try await Self.runTool(swift, ["build", "-c", "release"], directory: repository)
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path), FileManager.default.fileExists(atPath: databaseMarker.path) else {
            throw StudioError.message("Highball CLI or its Rockstar recipe is missing after setup.")
        }
        let home = WindowsRuntimeLayout.highballHome(in: workspace)
        return HighballSetup(binary: binary, repository: repository, home: home)
    }

    private func runCLI(_ binary: URL, _ arguments: [String], repository: URL, home: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = repository
            var environment = ProcessInfo.processInfo.environment
            environment["HIGHBALL_HOME"] = home.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(5000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func runTool(_ executable: URL, _ arguments: [String], directory: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(5000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func runWine(_ executable: URL, arguments: [String], prefix: URL, workingDirectory: URL,
                                            architecture: String? = nil, wineBinary: URL? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix.path
            environment["WINEDEBUG"] = "-all"
            if let architecture { environment["WINEARCH"] = architecture }
            if let wineBinary { environment["WINE"] = wineBinary.path }
            WindowsRuntimeLayout.configureGamepadEnvironment(&environment)
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(5000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private nonisolated static func wineOverrideValue(_ value: String) -> String {
        value.lowercased().split(separator: ",").map { part in
            switch part.trimmingCharacters(in: .whitespaces) {
            case "n": "native"
            case "b": "builtin"
            default: part.trimmingCharacters(in: .whitespaces)
            }
        }.joined(separator: ",")
    }

    private nonisolated static func latestRockstarEngine(in repository: URL) -> URL? {
        let directory = repository.appendingPathComponent("spike/engines", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.lastPathComponent.hasPrefix("x64-crossover26.3-r") && $0.pathExtension == "json" }
            .max { revision($0) < revision($1) }
    }

    private nonisolated static func revision(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        return Int(stem.split(separator: "r").last ?? "0") ?? 0
    }

    private nonisolated static func engineID(from manifest: URL) throws -> String {
        let data = try Data(contentsOf: manifest)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["id"] as? String,
              id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !id.contains("..") else {
            throw StudioError.message("Highball’s engine manifest has a missing or invalid engine id.")
        }
        return id
    }

    func install(client: String, workspace: URL?) async {
        if client == "Steam" { await installSteam(workspace: workspace); return }
        if client == "Rockstar" { await installRockstar(workspace: workspace); return }
        status = "This Windows client is not configured for Highball yet."
    }

    func launch(client: String, workspace: URL?) async {
        if client == "Steam" { await launchSteam(workspace: workspace); return }
        if client == "Rockstar" { await launchRockstar(workspace: workspace); return }
        status = "This Windows client is not configured for Highball yet."
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
