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
    static func root(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".nxstudio/Engines/WindowsGaming", isDirectory: true)
    }
    static func wine(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Wine", isDirectory: true)
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
    static func wineExecutable(in workspace: URL) -> URL? {
        let base = wine(in: workspace)
        let candidates = ["bin/wine64", "bin/wine", "wine.app/Contents/Resources/wine/bin/wine64"]
        if let direct = candidates.map({ base.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return direct }
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) else { return nil }
        while let file = enumerator.nextObject() as? URL {
            if ["wine64", "wine"].contains(file.lastPathComponent), file.pathComponents.contains("bin"),
               (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true { return file }
        }
        return nil
    }
    static func highballWineExecutable(in workspace: URL) -> URL? {
        let engines = highballHome(in: workspace).appendingPathComponent("engines", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: engines, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) else { return nil }
        while let file = enumerator.nextObject() as? URL {
            if ["wine64", "wine"].contains(file.lastPathComponent), file.pathComponents.contains("bin"),
               (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true { return file }
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

struct ManagedWindowsBottle: Sendable {
    let name: String
    let prefix: URL
    let wineExecutable: URL
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
                try process.run()
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
                            highballBottleName: "MetalOS-Epic", windowsStoreProvider: "epic", windowsStoreGameID: entry.appName)
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
                        highballBottleName: "MetalOS-GOG", windowsStoreProvider: "gog", windowsStoreGameID: String(id))
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
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
    @Published private(set) var progress: Double?

    func refresh(workspace: URL?) {
        guard let workspace else { status = "Choose a library folder first."; return }
        if let version = readVersion(in: workspace), WindowsRuntimeLayout.wineExecutable(in: workspace) != nil {
            installedVersion = version
            status = "Wine Staging \(version) is installed in your library folder."
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
        let archive = root.appendingPathComponent("wine-staging.tar.xz")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            status = "Checking the latest Wine Staging release…"
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!)
            request.setValue("MetalOS Windows runtime installer", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("GitHub did not return the Wine release information.") }
            let release = try JSONDecoder().decode(WindowsWineRelease.self, from: data)
            guard let asset = release.assets.first(where: { $0.name.hasPrefix("wine-staging-") && $0.name.hasSuffix("-osx64.tar.xz") }),
                  asset.size > 0, asset.size < 1_500_000_000,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else {
                throw StudioError.message("The latest Wine release has no supported macOS Staging archive and checksum.")
            }
            status = "Downloading Wine Staging \(release.tagName)…"
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
            status = "Verifying the Wine archive…"
            let listing = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
            let paths = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard !paths.isEmpty, paths.count < 500_000,
                  paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                throw StudioError.message("The Wine archive contains an invalid file path.")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            status = "Extracting Wine Staging \(release.tagName)…"
            _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
            let candidates = ["bin/wine64", "bin/wine", "wine.app/Contents/Resources/wine/bin/wine64"]
            guard candidates.map({ staging.appendingPathComponent($0) }).contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) || Self.findWine(in: staging) != nil else {
                throw StudioError.message("The Wine archive did not contain a supported Wine executable.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("Wine-backup-\(Int(Date().timeIntervalSince1970))"))
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            let marker = root.appendingPathComponent("wine-version.txt")
            try "\(release.tagName)\n\(release.htmlURL.absoluteString)\n".write(to: marker, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: archive)
            installedVersion = release.tagName
            status = "Wine Staging \(release.tagName) is ready. Create a Steam or Rockstar bottle next."
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
            try process.run()
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

    func installStandaloneInstaller(at installer: URL, workspace: URL?) async -> String? {
        guard !isWorking else { return nil }
        guard let workspace else { status = "Choose a library folder first."; return nil }
        guard installer.pathExtension.lowercased() == "exe", FileManager.default.isReadableFile(atPath: installer.path) else {
            status = "Choose a readable Windows .exe installer."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let setup = try await prepareHighballCLI(workspace: workspace)
            let manifest = setup.repository.appendingPathComponent("spike/engine-manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw StudioError.message("Highball’s checkout has no default Wine engine manifest.")
            }
            let engineID = try await ensureHighballEngine(manifest: manifest, label: "Windows game", setup: setup)
            let listing = try await runCLI(setup.binary, ["bottle", "list"], repository: setup.repository, home: setup.home)
            let baseName = Self.standaloneBottleBase(for: installer)
            let bottleName = Self.uniqueBottleName(base: baseName, listing: listing)
            status = "Creating a Highball bottle for \(installer.deletingPathExtension().lastPathComponent)…"
            _ = try await runCLI(setup.binary, ["bottle", "create", bottleName, "--engine", engineID], repository: setup.repository, home: setup.home)
            status = "Opening the Windows installer in its Highball bottle…"
            _ = try await runCLI(setup.binary, ["run", bottleName, installer.path], repository: setup.repository, home: setup.home)
            status = "Installer closed. Select the installed game’s .exe to add it to the library."
            return bottleName
        } catch {
            status = "Could not install the Windows game with Highball: \(error.localizedDescription)"
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

    func prepareStoreBottle(name: String, workspace: URL) async throws -> ManagedWindowsBottle {
        let setup = try await prepareHighballCLI(workspace: workspace)
        let manifest = setup.repository.appendingPathComponent("spike/engine-manifest.json")
        let engineID = try await ensureHighballEngine(manifest: manifest, label: name, setup: setup)
        let listing = try await runCLI(setup.binary, ["bottle", "list"], repository: setup.repository, home: setup.home)
        let exists = listing.split(separator: "\n").contains { $0.hasPrefix(name + "\t") }
        if !exists {
            status = "Creating the \(name) Windows bottle…"
            _ = try await runCLI(setup.binary, ["bottle", "create", name, "--engine", engineID], repository: setup.repository, home: setup.home)
        }
        let prefix = setup.home.appendingPathComponent("bottles/\(name)", isDirectory: true)
        let engineRoot = setup.home.appendingPathComponent("engines/\(engineID)", isDirectory: true)
        guard let wine = Self.findWineExecutable(in: engineRoot) else {
            throw StudioError.message("Highball installed the \(name) bottle, but its Wine executable could not be found.")
        }
        return ManagedWindowsBottle(name: name, prefix: prefix, wineExecutable: wine)
    }

    private nonisolated static func findWineExecutable(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]) else { return nil }
        while let file = enumerator.nextObject() as? URL {
            if ["wine64", "wine"].contains(file.lastPathComponent), file.pathComponents.contains("bin"),
               (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true { return file }
        }
        return nil
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
            try process.run()
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
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StudioError.message(String(decoding: data.suffix(5000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
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
        guard let id = object?["id"] as? String, id.hasPrefix("x64-crossover26.3-r") else {
            throw StudioError.message("The Highball Wine 11 manifest has an unexpected engine id.")
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
