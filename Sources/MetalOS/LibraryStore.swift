import AppKit
import SwiftUI
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published var data = LibraryData()
    @Published private(set) var setupComplete = false
    @Published private(set) var workspacePath = ""
    @Published var isScanning = false
    @Published var notice: String?
    @Published var scanWarnings: [String] = []
    @Published var source: GameSource = .all
    @Published var query = ""
    @Published var selectedID: String?
    @Published var console = false
    @Published var showingApps = false
    @Published var showSettings = false
    @Published var showImport = false
    @Published var showGameImport = false
    @Published var showBuild = false
    @Published private(set) var isImportingGame = false
    @Published private(set) var gameImportStatus = ""
    var openBuildAfterImport = false
    @Published var favoritesOnly = false
    let builder = NXBuildService()
    let artworkCredentials = ArtworkCredentialStore()
    private var switchArtworkAPI: SwitchArtworkAPI
    private let gameDBAPI = GameDBAPI()
    @Published private(set) var isFetchingArtwork = false
    @Published private(set) var artworkStatus = "GameDB artwork and metadata are available without API credentials."
    @Published private(set) var artworkMessages: [String: String] = [:]
    private let artworkAPI = ArtworkAPI()
    private var artworkCache: ArtworkCache
    private var artworkTask: Task<Void, Never>?
    private var queuedArtworkIDs: [String: Bool] = [:]
    private var storage: URL
    private var canSave = true
    private var launchAfterBuildID: String?
    private var gameProcess: Process?
    private var gameRunLog: FileHandle?
    private var gameConsoleLogReader: FileHandle?
    private var gameConsoleLogTimer: Timer?
    private var gameConsoleLogURL: URL?
    @Published private(set) var gameConsoleLog = ""
    private var buildObservation: AnyCancellable?
    private var volumeObservers: [NSObjectProtocol] = []
    private static let workspaceDefaultsKey = "NXStudio.workspacePath"
    private static let setupDefaultsKey = "NXStudio.setupComplete"
    var workspaceURL: URL? { workspacePath.isEmpty ? nil : URL(fileURLWithPath: workspacePath, isDirectory: true) }
    var visibleGames: [Game] {
        data.games.filter {
            $0.isGame != showingApps &&
            (source == .all || $0.source == source) && (!favoritesOnly || $0.favorite) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    var selected: Game? { visibleGames.first { $0.id == selectedID } ?? visibleGames.first }
    var canFetchArtwork: Bool { !data.games.isEmpty }
    private static func appDataDirectory(in workspace: URL) -> URL { workspace.appendingPathComponent(".nxstudio", isDirectory: true) }
    private static func libraryFile(in workspace: URL) -> URL { appDataDirectory(in: workspace).appendingPathComponent("library.json") }
    private static func artworkDirectory(in workspace: URL) -> URL { appDataDirectory(in: workspace).appendingPathComponent("Artwork", isDirectory: true) }
    private static func enginesDirectory(in workspace: URL) -> URL { appDataDirectory(in: workspace).appendingPathComponent("Engines", isDirectory: true) }
    init(storage: URL? = nil, artworkCache: ArtworkCache? = nil) {
        let defaults = UserDefaults.standard
        let savedWorkspace = defaults.string(forKey: Self.workspaceDefaultsKey) ?? ""
        let savedURL = URL(fileURLWithPath: savedWorkspace, isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasWorkspace = !savedWorkspace.isEmpty && FileManager.default.fileExists(atPath: savedWorkspace, isDirectory: &isDirectory) && isDirectory.boolValue
        let completed = defaults.bool(forKey: Self.setupDefaultsKey) && hasWorkspace
        self.setupComplete = completed
        self.workspacePath = completed ? savedURL.path : ""
        let legacyStorage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NXStudio/library.json")
        let resolvedStorage = completed ? Self.libraryFile(in: savedURL) : legacyStorage
        self.storage = storage ?? resolvedStorage
        let cacheRoot = completed ? Self.artworkDirectory(in: savedURL) : nil
        let cache = artworkCache ?? ArtworkCache(root: cacheRoot)
        self.artworkCache = cache
        self.switchArtworkAPI = SwitchArtworkAPI(cacheURL: cacheRoot?.appendingPathComponent("titledb-US.en.json"))
        if FileManager.default.fileExists(atPath: self.storage.path) {
            do { data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: self.storage)) }
            catch {
                let backup = self.storage.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                do {
                    try FileManager.default.copyItem(at: self.storage, to: backup)
                    notice = "Could not read your library. A backup was saved at \(backup.path)."
                } catch {
                    notice = "Could not read or back up the library. Saving is disabled to preserve the original file."
                    canSave = false
                }
            }
        }
        if completed {
            let oldManagedEngine = savedURL.appendingPathComponent(".nxstudio/Engines/NXNative", isDirectory: true).standardizedFileURL.path
            if URL(fileURLWithPath: data.settings.forkPath).standardizedFileURL.path == oldManagedEngine {
                // Keep the old checkout on disk, but require installation of the new default fork.
                data.settings.forkPath = ""
                save()
            }
        }
        NXBuildEnvironment.applyDefaults(to: &data.settings, discoverCheckout: false)
        // Existing imports follow the same folder-title rule, even while their drive is offline.
        for index in data.games.indices where data.games[index].source == .nxnative {
            if let input = data.games[index].buildInput, !input.isEmpty {
                data.games[index].title = URL(fileURLWithPath: input).lastPathComponent
            }
        }
        let originalGameCount = data.games.count
        data.games.removeAll { game in
            game.source == .steam || game.source == .heroic ||
            (game.id.hasPrefix("app:") && GameDiscovery.managerBundleIDs.contains(Bundle(path: game.installPath)?.bundleIdentifier ?? ""))
        }
        if data.games.count != originalGameCount { save() }
        builder.onComplete = { [weak self] id, url in
            guard let self, let i = self.data.games.firstIndex(where: { $0.id == id }) else { return }
            self.data.games[i].launchURL = url.absoluteString
            self.data.games[i].installPath = url.path
            self.data.games[i].builtNXProfileRevision = self.builder.profileRevisionUsed
            if let icon = SwitchGameDiscovery.extractedIcon(in: self.data.games[i].buildInput) {
                self.data.games[i].artworkPath = icon
            }
            self.save()
            if self.launchAfterBuildID == id {
                self.launchAfterBuildID = nil
                self.launch(self.data.games[i])
            }
        }
        builder.onRunReady = { [weak self] id, configuration in
            guard let self, let i = self.data.games.firstIndex(where: { $0.id == id }) else { return }
            self.data.games[i].runConfiguration = configuration
            self.data.games[i].launchURL = "nxnative-run://ready"
            self.data.games[i].installPath = configuration.executablePath
            self.data.games[i].builtNXProfileRevision = self.builder.profileRevisionUsed
            if let icon = SwitchGameDiscovery.extractedIcon(in: self.data.games[i].buildInput) {
                self.data.games[i].artworkPath = icon
            }
            self.save()
            if self.launchAfterBuildID == id {
                self.launchAfterBuildID = nil
                self.launch(self.data.games[i])
            }
        }
        buildObservation = builder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        console = data.settings.startInConsole
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.scan() }
            })
        }
        if canSave {
            let knownIDs = Set(data.games.map(\.id))
            Task { await cache.prune(keeping: knownIDs) }
        }
    }
    func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: storage, options: .atomic)
        } catch { notice = "Could not save library: \(error.localizedDescription)" }
    }
    func completeInitialSetup(at selectedFolder: URL) {
        let workspace = selectedFolder.standardizedFileURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.artworkDirectory(in: workspace), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.enginesDirectory(in: workspace), withIntermediateDirectories: true)
            let newStorage = Self.libraryFile(in: workspace)
            if !FileManager.default.fileExists(atPath: newStorage.path), FileManager.default.fileExists(atPath: storage.path) {
                try FileManager.default.copyItem(at: storage, to: newStorage)
            }
            let legacyArtwork = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NXStudio/Artwork", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacyArtwork.path) {
                for item in try FileManager.default.contentsOfDirectory(at: legacyArtwork, includingPropertiesForKeys: nil) {
                    let destination = Self.artworkDirectory(in: workspace).appendingPathComponent(item.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: item, to: destination) }
                }
            }
            workspacePath = workspace.path
            storage = newStorage
            data.settings.workspacePath = workspace.path
            data.settings.scanRoots = [workspace.path]
            let managedCheckout = Self.enginesDirectory(in: workspace).appendingPathComponent("NXNative-Yubismartlabs", isDirectory: true)
            if !NXBuildEnvironment.isCheckout(data.settings.forkPath) {
                data.settings.forkPath = NXBuildEnvironment.isCheckout(managedCheckout.path) ? managedCheckout.path : ""
            }
            let managedPython = Self.enginesDirectory(in: workspace).appendingPathComponent("Python/bin/python3")
            data.settings.pythonPath = FileManager.default.isExecutableFile(atPath: managedPython.path) ? managedPython.path : (NXBuildEnvironment.discoverPython() ?? data.settings.pythonPath)
            if !NXBuildEnvironment.isKeysFile(data.settings.keysPath), let keys = NXBuildEnvironment.discoverKeys() { data.settings.keysPath = keys }
            artworkCache = ArtworkCache(root: Self.artworkDirectory(in: workspace))
            switchArtworkAPI = SwitchArtworkAPI(cacheURL: Self.artworkDirectory(in: workspace).appendingPathComponent("titledb-US.en.json"))
            UserDefaults.standard.set(workspace.path, forKey: Self.workspaceDefaultsKey)
            UserDefaults.standard.set(true, forKey: Self.setupDefaultsKey)
            save()
            setupComplete = true
        } catch {
            notice = "Could not set up this folder: \(error.localizedDescription)"
        }
    }
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let roots = workspacePath.isEmpty ? data.settings.scanRoots : [workspacePath]
        let result = await GameDiscovery().scan(roots: roots)
        var discovered = result.games
        if let workspaceURL {
            discovered += GameDiscovery.windowsClientLaunchers(in: workspaceURL)
            discovered += GameDiscovery.windowsSteamGames(in: workspaceURL)
            discovered += await HighballLibraryDiscovery.scan(workspace: workspaceURL)
        }
        mergeDiscoveredGames(discovered)
        scanWarnings = result.warnings
        await checkNXSupport()
        isScanning = false
        save()
        fetchArtwork()
    }
    /// Merge Switch inputs by their folder even after installPath changes to the built app.
    func mergeDiscoveredGames(_ games: [Game]) {
        for game in games {
            if let index = data.games.firstIndex(where: {
                $0.id == game.id || ($0.source == game.source &&
                    ($0.installPath == game.installPath || (game.buildInput != nil && $0.buildInput == game.buildInput)))
            }) {
                data.games[index].title = game.title
                if game.source == .nxnative, game.buildInput != nil {
                    data.games[index].buildInput = game.buildInput
                    data.games[index].titleID = game.titleID
                    if let icon = SwitchGameDiscovery.extractedIcon(in: game.buildInput) { data.games[index].artworkPath = icon }
                    // Preserve an existing successful build and its launch URL.
                    if data.games[index].launchURL.isEmpty { data.games[index].installPath = game.installPath }
                } else {
                    data.games[index].installPath = game.installPath
                    data.games[index].launchURL = game.launchURL
                    if let libraryID = game.highballLibraryID { data.games[index].highballLibraryID = libraryID }
                    if let bottleName = game.highballBottleName { data.games[index].highballBottleName = bottleName }
                }
                if let path = game.artworkPath { data.games[index].artworkPath = path }
            } else { data.games.append(game) }
        }
    }
    func refreshWindowsGameEntries() {
        guard let workspaceURL else { return }
        mergeDiscoveredGames(GameDiscovery.windowsClientLaunchers(in: workspaceURL))
        save()
    }
    func checkNXSupport() async {
        guard data.games.contains(where: { $0.source == .nxnative }) else { return }
        let catalog: NXSupportCatalog?
        do { catalog = try await NXSupportCatalog.fetch() }
        catch { catalog = nil }
        for index in data.games.indices where data.games[index].source == .nxnative {
            if let catalog {
                data.games[index].nxSupport = catalog.status(titleID: data.games[index].titleID)
                if data.games[index].nxSupport?.state == .listed, let id = data.games[index].titleID {
                    do {
                        let revision = try await NXSupportCatalog.latestProfileRevision(titleID: id)
                        data.games[index].nxSupport?.latestProfileRevision = revision
                        // Existing builds may predate revision tracking or contain a SHA
                        // from the previous default fork. Baseline those once to avoid a
                        // false update prompt caused only by changing repositories.
                        if !data.games[index].launchURL.isEmpty,
                           data.games[index].builtNXProfileRevision == nil ||
                            !(data.games[index].builtNXProfileRevision?.hasPrefix("yubismartlabs:") ?? false) {
                            data.games[index].builtNXProfileRevision = revision
                        }
                    }
                    catch { data.games[index].nxSupport?.note += " Profile update check unavailable." }
                }
            }
            else {
                data.games[index].nxSupport = NXSupportStatus(state: .unknown, checkedAt: nil,
                    note: "Could not reach NXNative's official games table. Scan again to retry.")
            }
        }
        save()
    }
    func favorite(_ game: Game) {
        guard let i = data.games.firstIndex(where: { $0.id == game.id }) else { return }
        data.games[i].favorite.toggle(); save()
    }
    func launch(_ game: Game) {
        guard game.isAvailable else { notice = "This game is unavailable. Connect its drive or check its installation path."; return }
        if let executable = game.windowsExecutablePath, let bottle = game.windowsBottlePath {
            launchWindowsExecutable(game, executablePath: executable, bottlePath: bottle)
            return
        }
        if let url = URL(string: game.launchURL), url.scheme == "metalos-highball" {
            if let id = game.highballLibraryID {
                launchHighballLibraryGame(game, libraryID: id)
                return
            }
            launchHighballClient(game, client: url.host ?? "")
            return
        }
        if let url = URL(string: game.launchURL), url.scheme == "metalos-windows" {
            launchWindowsSteamGame(game, appID: url.pathComponents.last ?? "")
            return
        }
        if game.source == .nxnative, let configuration = game.runConfiguration {
            launchBuiltGame(game, configuration: configuration)
            return
        }
        guard !game.launchURL.isEmpty, let url = URL(string: game.launchURL) else {
            if game.source == .nxnative { startBuild(gameID: game.id, launchWhenComplete: true) }
            else { selectedID = game.id; showBuild = true }
            return
        }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.notice = "Could not launch \(game.title): \(error.localizedDescription)" }
                else if let i = self.data.games.firstIndex(where: { $0.id == game.id }) {
                    self.data.games[i].lastPlayed = Date(); self.save()
                    GameOverlayController.shared.beginSession(game: self.data.games[i], application: application)
                }
            }
        }
    }
    private func launchHighballClient(_ game: Game, client: String) {
        guard let workspaceURL, ["steam", "rockstar"].contains(client) else {
            notice = "This Highball launcher entry is not valid."
            return
        }
        let cli = WindowsRuntimeLayout.highballCLI(in: workspaceURL)
        let repository = WindowsRuntimeLayout.highballRepository(in: workspaceURL)
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path) else {
            notice = "The Highball CLI is unavailable. Reinstall the launcher from Settings → Windows Gaming."
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["run", client == "steam" ? "MetalOS-Steam" : "MetalOS-Rockstar",
                             client == "steam" ? "Steam" : "Rockstar Launcher"]
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["HIGHBALL_HOME"] = WindowsRuntimeLayout.highballHome(in: workspaceURL).path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if let index = data.games.firstIndex(where: { $0.id == game.id }) { data.games[index].lastPlayed = Date(); save() }
        } catch { notice = "Could not open \(game.title): \(error.localizedDescription)" }
    }

    private func launchHighballLibraryGame(_ game: Game, libraryID: String) {
        guard let workspaceURL, let bottleName = game.highballBottleName else {
            notice = "This Highball game is missing its bottle information. Scan the library again."
            return
        }
        let cli = WindowsRuntimeLayout.highballCLI(in: workspaceURL)
        let repository = WindowsRuntimeLayout.highballRepository(in: workspaceURL)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            notice = "The Highball CLI is unavailable. Set up a Highball Windows game from Settings → Windows Gaming."
            return
        }
        var arguments: [String]
        if libraryID.hasPrefix("steam:") {
            let appID = String(libraryID.dropFirst("steam:".count))
            arguments = ["run", bottleName, "Steam", "--", "-applaunch", appID]
        } else if libraryID.hasPrefix("epic:") {
            arguments = ["epic", "launch", bottleName, String(libraryID.dropFirst("epic:".count))]
        } else if libraryID.hasPrefix("gog:") {
            arguments = ["gog", "launch", bottleName, String(libraryID.dropFirst("gog:".count))]
        } else if libraryID.hasPrefix("pin:") {
            let pinName = Self.highballPinName(libraryID: libraryID, bottle: bottleName, home: WindowsRuntimeLayout.highballHome(in: workspaceURL)) ?? game.title
            arguments = ["run", bottleName, pinName]
        } else {
            notice = "Highball does not have a launch command for this library entry yet."
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["HIGHBALL_HOME"] = WindowsRuntimeLayout.highballHome(in: workspaceURL).path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if let index = data.games.firstIndex(where: { $0.id == game.id }) { data.games[index].lastPlayed = Date(); save() }
        } catch { notice = "Could not open \(game.title): \(error.localizedDescription)" }
    }

    private static func highballPinName(libraryID: String, bottle: String, home: URL) -> String? {
        guard let uuid = libraryID.split(separator: ":").last.map(String.init) else { return nil }
        let file = home.appendingPathComponent("bottles/\(bottle)/bottle.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]],
              let pin = pins.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame }) else { return nil }
        return pin["name"] as? String
    }

    private func launchWindowsSteamGame(_ game: Game, appID: String) {
        guard UInt64(appID) != nil, let workspaceURL else {
            notice = "Install Windows Steam in Settings → Windows Gaming first."
            return
        }
        let highballHome = WindowsRuntimeLayout.highballHome(in: workspaceURL)
        let highballSteam = highballHome.appendingPathComponent("bottles/MetalOS-Steam/drive_c/Program Files (x86)/Steam", isDirectory: true)
        let highballManifest = highballSteam.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        var environment = ProcessInfo.processInfo.environment
        let process = Process()
        if FileManager.default.fileExists(atPath: highballManifest.path) {
            let cli = WindowsRuntimeLayout.highballCLI(in: workspaceURL)
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                notice = "The Highball CLI is missing. Open Settings → Windows Gaming and set up Windows Steam again."
                return
            }
            process.executableURL = cli
            process.arguments = ["run", "MetalOS-Steam", "Steam", "--", "-applaunch", appID]
            process.currentDirectoryURL = WindowsRuntimeLayout.highballRepository(in: workspaceURL)
            environment["HIGHBALL_HOME"] = highballHome.path
        } else if let wine = WindowsRuntimeLayout.wineExecutable(in: workspaceURL) {
            // Keep games installed in an older MetalOS Wine bottle playable until their library is moved.
            let prefix = WindowsRuntimeLayout.bottle("Steam", in: workspaceURL).appendingPathComponent("prefix", isDirectory: true)
            let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
            guard FileManager.default.isReadableFile(atPath: steam.path) else {
                notice = "Install Windows Steam in Settings → Windows Gaming first."
                return
            }
            process.executableURL = wine
            process.arguments = [steam.path, "-applaunch", appID]
            environment["WINEPREFIX"] = prefix.path
            environment["WINEDEBUG"] = "-all"
        } else {
            notice = "Install Windows Steam in Settings → Windows Gaming first."
            return
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if let index = data.games.firstIndex(where: { $0.id == game.id }) { data.games[index].lastPlayed = Date(); save() }
        } catch { notice = "Could not launch \(game.title) through Windows Steam: \(error.localizedDescription)" }
    }
    private func launchWindowsExecutable(_ game: Game, executablePath: String, bottlePath: String) {
        guard let workspaceURL else {
            notice = "Choose a game library folder first."
            return
        }
        let bottle = URL(fileURLWithPath: bottlePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL.resolvingSymlinksInPath()
        let insideDriveC = executable.path.hasPrefix(bottle.path + "/drive_c/") || executable.path.hasPrefix(bottle.path + "/prefix/drive_c/")
        guard insideDriveC, FileManager.default.isReadableFile(atPath: executable.path) else {
            notice = "The Windows game executable is outside its managed bottle. Re-add it from Settings → Windows Gaming."
            return
        }
        var environment = ProcessInfo.processInfo.environment
        let process = Process()
        let highballBottles = WindowsRuntimeLayout.highballHome(in: workspaceURL).appendingPathComponent("bottles", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        if bottle.path.hasPrefix(highballBottles.path + "/") {
            let cli = WindowsRuntimeLayout.highballCLI(in: workspaceURL)
            let repository = WindowsRuntimeLayout.highballRepository(in: workspaceURL)
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                notice = "The Highball CLI is missing. Set up the Windows runtime from Settings → Windows Gaming."
                return
            }
            process.executableURL = cli
            process.arguments = ["run", bottle.lastPathComponent, executable.path]
            process.currentDirectoryURL = repository
            environment["HIGHBALL_HOME"] = WindowsRuntimeLayout.highballHome(in: workspaceURL).path
        } else {
            let expectedRoot = WindowsRuntimeLayout.bottles(in: workspaceURL).standardizedFileURL.resolvingSymlinksInPath()
            guard bottle.path.hasPrefix(expectedRoot.path + "/"), let wine = WindowsRuntimeLayout.wineExecutable(in: workspaceURL) else {
                notice = "The Windows game path is outside a supported managed bottle. Re-add it from Settings → Windows Gaming."
                return
            }
            environment["WINEPREFIX"] = bottle.path
            environment["WINEDEBUG"] = "-all"
            process.executableURL = wine
            process.arguments = [executable.path]
            process.currentDirectoryURL = executable.deletingLastPathComponent()
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if let index = data.games.firstIndex(where: { $0.id == game.id }) { data.games[index].lastPlayed = Date(); save() }
        } catch { notice = "Could not launch \(game.title): \(error.localizedDescription)" }
    }
    private func launchBuiltGame(_ game: Game, configuration: GameRunConfiguration) {
        if let gameProcess, gameProcess.isRunning {
            notice = "\(game.title) is already running."
            return
        }
        let executable = URL(fileURLWithPath: configuration.executablePath).standardizedFileURL
        let directory = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: directory.path) else {
            notice = "The built game files are unavailable. Rebuild this game to prepare them again."
            return
        }
        do {
            let logURL = directory.appendingPathComponent("host.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: logURL)
            try output.truncate(atOffset: 0)
            let process = Process()
            process.executableURL = executable
            process.arguments = configuration.arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment.merge(configuration.environment) { _, gameValue in gameValue }
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            let gameID = game.id
            process.terminationHandler = { [weak self] terminated in
                Task { @MainActor in
                    guard let self, self.gameProcess?.processIdentifier == terminated.processIdentifier else { return }
                    try? self.gameRunLog?.close()
                    self.gameRunLog = nil
                    self.gameProcess = nil
                    self.finishGameConsoleLog()
                    if let index = self.data.games.firstIndex(where: { $0.id == gameID }) {
                        self.data.games[index].lastPlayed = Date()
                        self.save()
                    }
                    GameFullScreenEnforcer.shared.endSession()
                }
            }
            try process.run()
            gameProcess = process
            gameRunLog = output
            startGameConsoleLog(at: logURL)
            if let index = data.games.firstIndex(where: { $0.id == game.id }) {
                data.games[index].lastPlayed = Date()
                save()
            }
            let application = NSRunningApplication(processIdentifier: process.processIdentifier)
            GameOverlayController.shared.beginSession(game: game, application: application)
        } catch {
            notice = "Could not start \(game.title): \(error.localizedDescription)"
        }
    }
    var hasRunningNXNativeGame: Bool { gameProcess?.isRunning == true && gameConsoleLogURL != nil }
    private func startGameConsoleLog(at url: URL) {
        gameConsoleLogTimer?.invalidate()
        try? gameConsoleLogReader?.close()
        gameConsoleLogURL = url
        gameConsoleLog = ""
        gameConsoleLogReader = try? FileHandle(forReadingFrom: url)
        refreshGameConsoleLog()
        gameConsoleLogTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGameConsoleLog() }
        }
    }
    private func refreshGameConsoleLog() {
        guard let gameConsoleLogReader, let data = try? gameConsoleLogReader.readToEnd(), !data.isEmpty else { return }
        gameConsoleLog += String(decoding: data, as: UTF8.self)
        if gameConsoleLog.count > 120_000 { gameConsoleLog = String(gameConsoleLog.suffix(100_000)) }
    }
    private func finishGameConsoleLog() {
        refreshGameConsoleLog()
        gameConsoleLogTimer?.invalidate(); gameConsoleLogTimer = nil
        try? gameConsoleLogReader?.close(); gameConsoleLogReader = nil
        gameConsoleLogURL = nil
    }
    func importApp() { showGameImport = true }
    func suggestedMacAppTitle(at url: URL) -> String {
        GameDiscovery.appGame(at: url, allowUncategorized: true)?.title
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
    @discardableResult func addMacApp(at url: URL, title customTitle: String? = nil) -> Bool {
        guard url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) else {
            notice = "Choose a macOS game application or a CrossOver app launcher."; return false
        }
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = data.games.firstIndex(where: { $0.installPath == url.path }) {
            if let title, !title.isEmpty, data.games[index].title != title {
                data.games[index].title = title
                data.games[index].artworkCheckedAt = nil
                save()
                fetchArtwork(gameID: data.games[index].id, force: true)
            }
            selectedID = data.games[index].id
            return true
        }
        let discovered = GameDiscovery.appGame(at: url, allowUncategorized: true)
        let fallbackTitle = discovered?.title ?? suggestedMacAppTitle(at: url)
        let game = Game(id: "manual:\(url.path)", title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle, source: discovered?.source ?? .native, launchURL: url.absoluteString, installPath: url.path, titleID: discovered?.titleID, isGameApp: discovered?.isGame ?? false)
        data.games.append(game); source = .all; showingApps = !game.isGame; selectedID = game.id; save()
        if game.source == .nxnative { Task { await checkNXSupport() } }
        fetchArtwork(gameID: game.id, force: true)
        return true
    }
    @discardableResult func addWindowsGame(at url: URL) -> Bool {
        guard let workspaceURL, url.pathExtension.lowercased() == "exe" else {
            notice = "Choose a Windows .exe game installed inside a managed bottle."
            return false
        }
        let bottlesRoot = WindowsRuntimeLayout.bottles(in: workspaceURL).standardizedFileURL.resolvingSymlinksInPath()
        let executable = url.standardizedFileURL.resolvingSymlinksInPath()
        guard executable.path.hasPrefix(bottlesRoot.path + "/"), FileManager.default.isReadableFile(atPath: executable.path) else {
            notice = "The game executable must be inside a MetalOS Windows bottle."
            return false
        }
        let components = executable.pathComponents
        guard let prefixIndex = components.firstIndex(of: "prefix"), prefixIndex > 0 else {
            notice = "Choose a game executable inside a Windows bottle’s prefix folder."
            return false
        }
        let bottle = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<prefixIndex])), isDirectory: true)
        guard bottle.path.hasPrefix(bottlesRoot.path + "/") else {
            notice = "The selected executable is not inside a supported Windows bottle."
            return false
        }
        if let existing = data.games.first(where: { $0.windowsExecutablePath == executable.path }) {
            selectedID = existing.id
            return true
        }
        let title = executable.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let id = "windows-exe:\(UUID().uuidString)"
        let game = Game(id: id, title: title, source: .windows, launchURL: "metalos-windows://exe/\(id)", installPath: executable.path,
                        windowsExecutablePath: executable.path, windowsBottlePath: bottle.path)
        data.games.append(game)
        source = .all
        showingApps = false
        selectedID = game.id
        save()
        fetchArtwork(gameID: game.id, force: true)
        return true
    }
    @discardableResult func addHighballWindowsGame(at url: URL, bottleName: String) -> Bool {
        guard let workspaceURL, url.pathExtension.lowercased() == "exe", !bottleName.isEmpty,
              !bottleName.contains("/"), bottleName != ".", bottleName != ".." else {
            notice = "Choose a Windows .exe installed in a Highball bottle."
            return false
        }
        let bottlesRoot = WindowsRuntimeLayout.highballHome(in: workspaceURL).appendingPathComponent("bottles", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let bottle = bottlesRoot.appendingPathComponent(bottleName, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let executable = url.standardizedFileURL.resolvingSymlinksInPath()
        guard bottle.deletingLastPathComponent().path == bottlesRoot.path,
              executable.path.hasPrefix(bottle.path + "/drive_c/"),
              FileManager.default.isReadableFile(atPath: executable.path) else {
            notice = "Choose the installed game executable inside this Highball bottle’s drive_c folder."
            return false
        }
        if let existing = data.games.first(where: { $0.windowsExecutablePath == executable.path }) {
            selectedID = existing.id
            return true
        }
        let title = executable.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let id = "highball-exe:\(UUID().uuidString)"
        let game = Game(id: id, title: title, source: .windows, launchURL: "metalos-highball://program", installPath: executable.path,
                        windowsExecutablePath: executable.path, windowsBottlePath: bottle.path)
        data.games.append(game)
        source = .all
        showingApps = false
        selectedID = game.id
        save()
        fetchArtwork(gameID: game.id, force: true)
        return true
    }
    func importSwitch(baseGame basePath: String, update updatePath: String?, dlcs dlcPaths: [String]) {
        guard !isImportingGame else { return }
        guard let workspace = workspaceURL else { notice = "Choose your game library folder in setup first."; return }
        isImportingGame = true
        gameImportStatus = "Preparing game files…"
        showImport = false
        let base = URL(fileURLWithPath: basePath).standardizedFileURL.resolvingSymlinksInPath()
        let packages = [base] + (updatePath.map { [URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()] } ?? []) + dlcPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        guard SwitchGameDiscovery.extensions.contains(base.pathExtension.lowercased()),
              packages.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            isImportingGame = false
            notice = "Choose readable Switch game package files."
            return
        }
        let parsedTitle = GameTitleMatcher.searchTitle(base.lastPathComponent)
        let titleID = SwitchGameDiscovery.titleIDs(in: base.lastPathComponent).first(where: { $0.hasSuffix("000") })
        let rawTitle = parsedTitle.isEmpty ? (titleID.map { "Switch Game \($0.suffix(6))" } ?? base.deletingPathExtension().lastPathComponent) : parsedTitle
        let fallbackFolderName = rawTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackFolderName.isEmpty, fallbackFolderName != ".", fallbackFolderName != ".." else {
            isImportingGame = false
            notice = "MetalOS could not read a usable title from the base game file name."
            return
        }
        Task {
            defer { isImportingGame = false; gameImportStatus = "" }
            do {
                var folderName = fallbackFolderName
                if parsedTitle.isEmpty, let titleID,
                   let catalogTitle = await switchArtworkAPI.titleName(titleID: titleID), !catalogTitle.isEmpty {
                    folderName = catalogTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let folder = workspace.appendingPathComponent(folderName, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: folder.path) else {
                    throw StudioError.message("\(folderName) is already in your game library.")
                }
                let staging = Self.appDataDirectory(in: workspace).appendingPathComponent("Importing/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                gameImportStatus = "Adding \(folderName) to your game library…"
                do {
                    try await Task.detached(priority: .utility) {
                        var usedNames = Set<String>()
                        for package in packages {
                            var fileName = package.lastPathComponent
                            if !usedNames.insert(fileName.lowercased()).inserted {
                                let source = URL(fileURLWithPath: fileName)
                                var suffix = 2
                                repeat {
                                    fileName = source.deletingPathExtension().lastPathComponent + " (\(suffix))." + source.pathExtension
                                    suffix += 1
                                } while !usedNames.insert(fileName.lowercased()).inserted
                            }
                            try FileManager.default.copyItem(at: package, to: staging.appendingPathComponent(fileName))
                        }
                    }.value
                    try FileManager.default.moveItem(at: staging, to: folder)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                gameImportStatus = "Preparing \(folderName)…"
                let detected = await Task.detached(priority: .utility) {
                    SwitchGameDiscovery.scan(root: folder).games.first { $0.buildInput == folder.path }
                }.value
                var game = detected ?? Game(id: "switch:\(folder.path)", title: folderName, source: .nxnative, launchURL: "", installPath: folder.path, buildInput: folder.path, titleID: titleID)
                game.title = folderName
                if game.titleID == nil { game.titleID = titleID }
                NXBuildEnvironment.applyDefaults(to: &data.settings, discoverCheckout: false)
                mergeDiscoveredGames([game])
                if let index = data.games.firstIndex(where: { $0.buildInput == folder.path }) {
                    data.games[index].forkPath = nil
                    selectedID = data.games[index].id
                }
                source = .nxnative; showingApps = false; save(); openBuildAfterImport = false
                Task { await checkNXSupport() }
                fetchArtwork()
            } catch {
                notice = "Could not add this game: \(error.localizedDescription)"
            }
        }
    }
    func startBuild(gameID: String, launchWhenComplete: Bool = false) {
        guard let index = data.games.firstIndex(where: { $0.id == gameID }), data.games[index].source == .nxnative else { return }
        NXBuildEnvironment.applyDefaults(to: &data.settings, discoverCheckout: false)
        selectedID = gameID
        save()
        showBuild = true
        launchAfterBuildID = launchWhenComplete ? gameID : nil
        builder.start(game: data.games[index], settings: data.settings)
        if !builder.isBuilding { launchAfterBuildID = nil }
    }
    func removeGame(id: String) {
        let legacyPaths = data.games.first(where: { $0.id == id }).map {
            [$0.boxArt?.path, $0.heroArt?.path].compactMap { $0 }
        } ?? []
        data.games.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        artworkMessages[id] = nil
        save()
        for path in legacyPaths { ArtworkCache.removeLegacyCachedFile(atPath: path) }
        Task { await artworkCache.removeArtwork(for: id) }
    }
    func prepareArtwork() { artworkCredentials.load() }
    func fetchArtwork(gameID: String? = nil, force: Bool = false) {
        if isFetchingArtwork {
            let ids = gameID.map { [$0] } ?? data.games.map(\.id)
            for id in ids { queuedArtworkIDs[id] = (queuedArtworkIDs[id] ?? false) || force }
            return
        }
        let credentials = artworkCredentials.values
        let pending = data.games.filter { game in
            if let gameID, game.id != gameID { return false }
            if force { return true }
            let coverMissing = game.boxArt.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            let heroMissing = game.heroArt.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            let metadataMissing = game.metadata == nil
            return (coverMissing || heroMissing || metadataMissing) && (game.artworkCheckedAt.map { Date().timeIntervalSince($0) > 86_400 } ?? true)
        }
        guard !pending.isEmpty else { artworkStatus = "Game artwork and details are up to date."; return }
        artworkStatus = "Finding artwork and game details…"
        isFetchingArtwork = true
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isFetchingArtwork = false
                self.artworkTask = nil
                if let nextID = self.queuedArtworkIDs.keys.sorted().first {
                    let nextForce = self.queuedArtworkIDs.removeValue(forKey: nextID) ?? false
                    self.fetchArtwork(gameID: nextID, force: nextForce)
                }
            }
            var updated = 0
            for (number, snapshot) in pending.enumerated() {
                guard !Task.isCancelled else { break }
                self.artworkStatus = "Finding artwork \(number + 1)/\(pending.count): \(snapshot.title)"
                // The library title is authoritative, including a user-entered Mac app title.
                var result = await self.gameDBAPI.lookup(title: snapshot.title)
                if snapshot.source == .nxnative {
                    let fallback = await self.switchArtworkAPI.lookup(titleID: snapshot.titleID)
                    result = Self.addFallback(fallback, to: result)
                } else if credentials.isConfigured && (!result.assets.contains(where: { $0.kind == .cover }) || !result.assets.contains(where: { $0.kind == .hero })) {
                    let fallback = await self.artworkAPI.lookup(title: snapshot.title, credentials: credentials)
                    result = Self.addFallback(fallback, to: result)
                }
                guard self.data.games.contains(where: {
                    $0.id == snapshot.id && $0.title == snapshot.title
                }) else { continue }
                var downloaded: [(ArtworkKind, ArtworkRecord)] = []
                var messages = result.messages
                for asset in result.assets {
                    guard !Task.isCancelled else { break }
                    do { downloaded.append((asset.kind, try await self.artworkCache.fetch(asset, gameID: snapshot.id, replacing: force))) }
                    catch { messages.append("Could not download \(asset.kind.rawValue) artwork from \(asset.provider).") }
                }
                guard !Task.isCancelled else { break }
                guard let index = self.data.games.firstIndex(where: { $0.id == snapshot.id }) else {
                    await self.artworkCache.removeArtwork(for: snapshot.id)
                    continue
                }
                guard self.data.games[index].title == snapshot.title else {
                    let keep = Set([self.data.games[index].boxArt?.path, self.data.games[index].heroArt?.path]
                        .compactMap { $0 } + (self.data.games[index].metadata?.screenshots.map(\.path) ?? []))
                    await self.artworkCache.retainArtwork(for: snapshot.id, paths: keep)
                    continue
                }
                for (kind, record) in downloaded {
                    if kind == .screenshot { continue }
                    let previous = kind == .cover ? self.data.games[index].boxArt : self.data.games[index].heroArt
                    if kind == .cover { self.data.games[index].boxArt = record }
                    else { self.data.games[index].heroArt = record }
                    if let previous, previous.path != record.path { ArtworkCache.removeLegacyCachedFile(atPath: previous.path) }
                }
                if var metadata = result.metadata {
                    let freshScreenshots = downloaded.filter { $0.0 == .screenshot }.map(\.1)
                    let expectedScreenshots = Set(result.assets.filter { $0.kind == .screenshot }.map { $0.url.absoluteString })
                    let freshScreenshotURLs = Set(freshScreenshots.compactMap(\.sourceURL))
                    let retainedScreenshots = (self.data.games[index].metadata?.screenshots ?? []).filter {
                        guard let source = $0.sourceURL else { return false }
                        return expectedScreenshots.contains(source) && !freshScreenshotURLs.contains(source)
                    }
                    metadata.screenshots = expectedScreenshots.isEmpty ? [] : Array((freshScreenshots + retainedScreenshots).prefix(8))
                    self.data.games[index].metadata = metadata
                }
                let keep = Set([self.data.games[index].boxArt?.path, self.data.games[index].heroArt?.path]
                    .compactMap { $0 } + (self.data.games[index].metadata?.screenshots.map(\.path) ?? []))
                await self.artworkCache.retainArtwork(for: snapshot.id, paths: keep)
                if !downloaded.isEmpty || result.metadata != nil {
                    updated += 1
                    if let matchedTitle = result.matchedTitle { self.data.games[index].artworkMatchedTitle = matchedTitle }
                }
                if snapshot.source == .nxnative,
                   let icon = SwitchGameDiscovery.extractedIcon(in: self.data.games[index].buildInput) {
                    self.data.games[index].artworkPath = icon
                }
                let retryableArtworkFailure = messages.contains {
                    $0.hasPrefix("GameDB could not be reached") ||
                    $0.hasPrefix("GameDB lookup failed:") ||
                    $0.hasPrefix("GameDB returned data MetalOS could not read:") ||
                    $0.hasPrefix("Could not download ")
                }
                // Don't suppress retries for a transient network, decode, or image-download failure.
                self.data.games[index].artworkCheckedAt = retryableArtworkFailure ? nil : Date()
                self.artworkMessages[snapshot.id] = messages.isEmpty ? "Artwork downloaded and stored." : messages.joined(separator: "\n")
                self.save()
            }
            self.artworkStatus = Task.isCancelled ? "Artwork fetching stopped." : "Artwork checked. Updated \(updated) of \(pending.count) games."
        }
    }
    func cancelArtwork() { artworkTask?.cancel() }

    private static func addFallback(_ fallback: ArtworkLookupResult, to primary: ArtworkLookupResult) -> ArtworkLookupResult {
        var combined = primary
        let existingKinds = Set(combined.assets.map(\.kind))
        combined.assets.append(contentsOf: fallback.assets.filter { !existingKinds.contains($0.kind) && $0.kind != .screenshot })
        if combined.matchedTitle == nil { combined.matchedTitle = fallback.matchedTitle }
        if combined.assets.isEmpty { combined.messages.append(contentsOf: fallback.messages) }
        return combined
    }
    func moveSelection(_ delta: Int) {
        let games = visibleGames
        guard !games.isEmpty else { return }
        let index = games.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = games[min(max(index + delta, 0), games.count - 1)].id
    }
    func changeSource(_ delta: Int) {
        let sources = GameSource.allCases
        let i = sources.firstIndex(of: source) ?? 0
        source = sources[(i + delta + sources.count) % sources.count]; selectedID = visibleGames.first?.id
    }
    func toggleConsole() {
        console.toggle()
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain && $0.sheetParent == nil }), window.styleMask.contains(.fullScreen) != console { window.toggleFullScreen(nil) }
    }
}
