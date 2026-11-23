import AppKit
import CryptoKit
import Foundation

/// The existing library store remains the persistence authority; this name exposes its
/// console-facing role while preserving compatibility with the desktop library screens.
typealias GameLibraryStore = LibraryStore

struct GameScannerService: Sendable {
    func scan(roots: [String], emulatorProfiles: [EmulatorProfile]) async -> DiscoveryResult {
        await Task.detached(priority: .utility) {
            Self.scanSynchronously(roots: roots, emulatorProfiles: emulatorProfiles)
        }.value
    }

    private static func scanSynchronously(roots: [String], emulatorProfiles: [EmulatorProfile]) -> DiscoveryResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoots = ["/Applications", home.appendingPathComponent("Applications").path]
        let allRoots = Array(Set((defaultRoots + roots).map(expandedPath))).sorted()
        let consoleRoots = allRoots.filter { path in
            path != expandedPath("/Applications") && path != expandedPath(home.appendingPathComponent("Applications").path)
        }
        var result = GameDiscovery.scanLocalForConsole(roots: consoleRoots)
        result.games += scanNativeApps(roots: allRoots)
        result.games += scanSteam(home: home)
        result.games += scanCrossOver(home: home)
        result.games += scanWhisky(home: home)
        result.games += scanROMs(profiles: emulatorProfiles)

        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        result.games = result.games.filter { game in
            let path = URL(fileURLWithPath: game.installPath).standardizedFileURL.path
            return seenIDs.insert(game.id).inserted && seenPaths.insert(path).inserted
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }

    private static func expandedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.appstore", "com.apple.systempreferences", "com.apple.finder", "com.apple.safari",
        "com.apple.stocks", "com.apple.calculator", "com.apple.preview", "com.apple.activitymonitor",
        "com.valvesoftware.steam", "com.codeweavers.crossover", "com.isaacmarovitz.whisky",
        "com.heroicgameslauncher.hgl", "org.nxnative.nsportbuilder", "com.varyform.nxplay"
    ]

    private static func scanNativeApps(roots: [String]) -> [Game] {
        let fm = FileManager.default
        var apps = Set<String>()
        for path in roots {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard fm.fileExists(atPath: root.path) else { continue }
            if root.pathExtension.lowercased() == "app" {
                apps.insert(root.standardizedFileURL.path)
                continue
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "app" {
                    apps.insert(url.standardizedFileURL.path)
                    enumerator.skipDescendants()
                }
            }
        }
        return apps.sorted().compactMap { path in
            let app = URL(fileURLWithPath: path)
            guard let info = infoDictionary(for: app) else { return nil }
            let bundleID = info["CFBundleIdentifier"] as? String ?? ""
            guard !excludedBundleIDs.contains(bundleID), !GameDiscovery.managerBundleIDs.contains(bundleID) else { return nil }
            let category = info["LSApplicationCategoryType"] as? String ?? ""
            let gameCategory = category == "public.app-category.games" || category.localizedCaseInsensitiveContains("games")
            let hasGameRuntime = hasGameEngineSignature(app)
            let isCrossOverWrapper = app.path.localizedCaseInsensitiveContains("/CrossOver/")
            guard gameCategory || hasGameRuntime || isCrossOverWrapper else { return nil }
            guard var game = GameDiscovery.appGame(at: app, allowUncategorized: true) else { return nil }
            game.id = "macos:\(bundleID.isEmpty ? stableHash(app.standardizedFileURL.path) : bundleID)"
            game.source = isCrossOverWrapper ? .crossover : game.source
            game.isGameApp = true
            game.platformBadge = isCrossOverWrapper ? "Windows" : "macOS"
            game.normalizedTitle = GameDBService.sanitizeTitle(game.title)
            game.launchSpec = .appBundle(appURL: app, bundleID: bundleID.isEmpty ? nil : bundleID)
            return game
        }
    }

    private static func infoDictionary(for app: URL) -> [String: Any]? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return value
    }

    private static func hasGameEngineSignature(_ app: URL) -> Bool {
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let candidates = ["UnityPlayer.dylib", "UE4", "Unreal", "Godot", "SDL2.framework", "SDL3.framework", "GameController.framework"]
        return candidates.contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
            || FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/Metal.framework").path)
    }

    private static func scanSteam(home: URL) -> [Game] {
        let steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        let manifestURL = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        var libraries = [steamRoot]
        if let text = try? String(contentsOf: manifestURL, encoding: .utf8) {
            let root = VDFParser.parse(text)
            let folderObject = root["libraryfolders"]?.objectValue ?? root
            for value in folderObject.values {
                if case .string(let path) = value { libraries.append(URL(fileURLWithPath: expandedPath(path), isDirectory: true)) }
                else if let path = value.objectValue?["path"]?.stringValue {
                    libraries.append(URL(fileURLWithPath: expandedPath(path), isDirectory: true))
                }
            }
        }
        var games: [Game] = []
        var ids = Set<String>()
        for library in libraries {
            let steamApps = library.appendingPathComponent("steamapps", isDirectory: true)
            guard let manifests = try? FileManager.default.contentsOfDirectory(at: steamApps, includingPropertiesForKeys: nil) else { continue }
            for file in manifests where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension.lowercased() == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let root = VDFParser.parse(text)
                let state = root["AppState"]?.objectValue ?? root
                guard let appID = state["appid"]?.stringValue, UInt64(appID) != nil,
                      let name = state["name"]?.stringValue, !name.isEmpty,
                      let directory = state["installdir"]?.stringValue, !directory.contains("/"), !directory.contains("\\") else { continue }
                let flags = UInt32(state["StateFlags"]?.stringValue ?? "0") ?? 0
                guard flags & 4 != 0, !isSteamRuntime(name), ids.insert(appID).inserted else { continue }
                let install = library.appendingPathComponent("steamapps/common").appendingPathComponent(directory)
                var game = Game(id: "steam:\(appID)", title: name, source: .steam,
                    launchURL: "steam://rungameid/\(appID)", installPath: install.path)
                game.platformBadge = "Steam"
                game.normalizedTitle = GameDBService.sanitizeTitle(name)
                game.launchSpec = .steam(appID: appID)
                games.append(game)
            }
        }
        return games
    }

    private static func isSteamRuntime(_ name: String) -> Bool {
        let value = name.lowercased()
        return ["steamworks common redistributables", "proton", "steam linux runtime", "soundtrack", "dedicated server"]
            .contains(where: value.contains)
    }

    private static func scanCrossOver(home: URL) -> [Game] {
        var games: [Game] = []
        let wrappers = [home.appendingPathComponent("Applications/CrossOver", isDirectory: true),
                        URL(fileURLWithPath: "/Applications/CrossOver", isDirectory: true)]
        for root in wrappers {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in files where app.pathExtension.lowercased() == "app" {
                guard var game = GameDiscovery.appGame(at: app, allowUncategorized: true) else { continue }
                game.id = "crossover:wrapper:\(stableHash(app.standardizedFileURL.path))"
                game.source = .crossover
                game.isGameApp = true
                game.platformBadge = "Windows"
                game.normalizedTitle = GameDBService.sanitizeTitle(game.title)
                game.launchSpec = .appBundle(appURL: app, bundleID: infoDictionary(for: app)?["CFBundleIdentifier"] as? String)
                games.append(game)
            }
        }

        let bottleRoot = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        guard let bottles = try? FileManager.default.contentsOfDirectory(at: bottleRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return games }
        for bottle in bottles {
            let searchRoots = ["drive_c/Program Files", "drive_c/Program Files (x86)"]
                .map { bottle.appendingPathComponent($0, isDirectory: true) }
            games += scanBottleExecutables(bottle: bottle, searchRoots: searchRoots, source: .crossover)
        }
        return games
    }

    private static func scanWhisky(home: URL) -> [Game] {
        let bottlesRoot = home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles", isDirectory: true)
        guard let bottles = try? FileManager.default.contentsOfDirectory(at: bottlesRoot, includingPropertiesForKeys: nil) else { return [] }
        return bottles.flatMap { bottle -> [Game] in
            let metadataURL = bottle.appendingPathComponent("Metadata.plist")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let pins = metadata["pins"] as? [Any] else { return [] }
            return pins.compactMap { pin in
                let fields = pin as? [String: Any]
                let rawPath = (fields?["path"] as? String) ?? (fields?["executable"] as? String) ?? (fields?["exe"] as? String) ?? (pin as? String)
                guard let rawPath, rawPath.lowercased().hasSuffix(".exe") else { return nil }
                let executable = URL(fileURLWithPath: expandedPath(rawPath.hasPrefix("/") ? rawPath : bottle.appendingPathComponent(rawPath).path))
                let title = (fields?["name"] as? String) ?? executable.deletingPathExtension().lastPathComponent
                return makeBottleGame(title: title, bottle: bottle, executable: executable, source: .whisky)
            }
        }
    }

    private static func scanBottleExecutables(bottle: URL, searchRoots: [URL], source: GameSource) -> [Game] {
        var games: [Game] = []
        for root in searchRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "exe", !isWindowsUtility(url.deletingPathExtension().lastPathComponent) else { continue }
                games.append(makeBottleGame(title: url.deletingPathExtension().lastPathComponent, bottle: bottle, executable: url, source: source))
                enumerator.skipDescendants()
            }
        }
        return games
    }

    private static func isWindowsUtility(_ title: String) -> Bool {
        let value = title.lowercased()
        return ["unins", "uninstall", "setup", "vc_redist", "dxsetup", "crashreport", "updater", "launcher installer"]
            .contains(where: value.contains)
    }

    private static func makeBottleGame(title: String, bottle: URL, executable: URL, source: GameSource) -> Game {
        let bottleName = bottle.lastPathComponent
        let id = "\(source == .whisky ? "whisky" : "crossover"):\(bottleName):\(stableHash(executable.standardizedFileURL.path))"
        var game = Game(id: id, title: title, source: source, launchURL: "metalos-bottle://launch", installPath: executable.path,
            windowsExecutablePath: executable.path, windowsBottlePath: bottle.path)
        game.isGameApp = true
        game.platformBadge = "Windows · \(bottleName)"
        game.normalizedTitle = GameDBService.sanitizeTitle(title)
        game.launchSpec = .bottle(bottleName: bottleName, bottlePath: bottle, executableURL: executable, wrapperURL: nil)
        return game
    }

    private static func scanROMs(profiles: [EmulatorProfile]) -> [Game] {
        profiles.filter(\.enabled).flatMap { profile -> [Game] in
            let root = profile.romDirectoryURL
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            let allowed = Set(profile.fileExtensions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
            var games: [Game] = []
            while let rom = enumerator.nextObject() as? URL {
                guard allowed.contains(rom.pathExtension.lowercased()) else { continue }
                let title = rom.deletingPathExtension().lastPathComponent
                let args = (profile.argumentTemplate.isEmpty ? ["{rom}"] : profile.argumentTemplate)
                    .map { $0.replacingOccurrences(of: "{rom}", with: rom.path) }
                let id = "emu:\(profile.id):\(stableHash(rom.standardizedFileURL.path))"
                var game = Game(id: id, title: title, source: .emulator,
                    launchURL: "metalos-emulator://\(profile.id)", installPath: rom.path)
                game.isGameApp = true
                game.platformBadge = profile.platformLabel
                game.normalizedTitle = GameDBService.sanitizeTitle(title)
                game.launchSpec = .emulator(emulatorAppURL: profile.emulatorAppURL, romURL: rom, arguments: args)
                games.append(game)
            }
            return games
        }
    }

    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private indirect enum VDFValue {
    case string(String)
    case object([String: VDFValue])
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var objectValue: [String: VDFValue]? { if case .object(let value) = self { value } else { nil } }
}

private enum VDFParser {
    private enum Token { case value(String), open, close }

    static func parse(_ text: String) -> [String: VDFValue] {
        var tokens = tokenize(text)
        var index = 0
        return parseObject(tokens: &tokens, index: &index, untilClose: false)
    }

    private static func parseObject(tokens: inout [Token], index: inout Int, untilClose: Bool) -> [String: VDFValue] {
        var result: [String: VDFValue] = [:]
        while index < tokens.count {
            if case .close = tokens[index] { index += 1; if untilClose { break }; continue }
            guard case .value(let key) = tokens[index] else { index += 1; continue }
            index += 1
            guard index < tokens.count else { break }
            switch tokens[index] {
            case .open:
                index += 1
                result[key] = .object(parseObject(tokens: &tokens, index: &index, untilClose: true))
            case .value(let value): index += 1; result[key] = .string(value)
            case .close: index += 1
            }
        }
        return result
    }

    private static func tokenize(_ text: String) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            if chars[index].isWhitespace { index += 1; continue }
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
                continue
            }
            if chars[index] == "{" { tokens.append(.open); index += 1; continue }
            if chars[index] == "}" { tokens.append(.close); index += 1; continue }
            if chars[index] == "\"" {
                index += 1
                var value = ""
                while index < chars.count {
                    let char = chars[index]
                    index += 1
                    if char == "\\", index < chars.count { value.append(chars[index]); index += 1 }
                    else if char == "\"" { break }
                    else { value.append(char) }
                }
                tokens.append(.value(value))
                continue
            }
            var value = ""
            while index < chars.count && !chars[index].isWhitespace && chars[index] != "{" && chars[index] != "}" {
                value.append(chars[index]); index += 1
            }
            if !value.isEmpty { tokens.append(.value(value)) }
        }
        return tokens
    }
}

@MainActor
final class GameLaunchCoordinator: ObservableObject {
    private final class ApplicationMatch: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NSRunningApplication?
        func set(_ value: NSRunningApplication) { lock.lock(); stored = value; lock.unlock() }
        func get() -> NSRunningApplication? { lock.lock(); defer { lock.unlock() }; return stored }
    }
    static let shared = GameLaunchCoordinator()
    @Published private(set) var splashGameID: String?
    private var dismissalTask: Task<Void, Never>?

    private init() {}

    func launch(_ game: Game, through store: LibraryStore) {
        guard game.isAvailable else {
            UISoundManager.playBoundaryBump()
            ConsoleToastManager.shared.post("Unable to Launch", "\(game.title) is unavailable. Connect its drive or check the install path.", symbol: "externaldrive.badge.xmark", priority: .warning)
            return
        }
        dismissalTask?.cancel()
        splashGameID = game.id
        UISoundManager.playConfirm()
        switch game.launchSpec {
        case .some(.steam(let appID)):
            if game.launchURL.hasPrefix("metalos-windows://") {
                store.launch(game)
                dismissalTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.finish(gameID: game.id)
                }
            } else {
                launchSteam(game, appID: appID, through: store)
            }
        default:
            store.launch(game)
            dismissalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.finish(gameID: game.id)
            }
        }
    }

    func handoffStarted(gameID: String) { finish(gameID: gameID) }
    func gameSessionEnded(gameID: String?) {
        if gameID == nil || splashGameID == gameID { finish(gameID: gameID) }
    }

    private func finish(gameID: String?) {
        guard gameID == nil || splashGameID == gameID else { return }
        dismissalTask?.cancel()
        dismissalTask = nil
        splashGameID = nil
    }

    private func launchSteam(_ game: Game, appID: String, through store: LibraryStore) {
        let targetPath = URL(fileURLWithPath: game.installPath).standardizedFileURL.path
        let workspace = NSWorkspace.shared
        let match = ApplicationMatch()
        let center = workspace.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundlePath = application.bundleURL?.standardizedFileURL.path,
                  bundlePath.hasPrefix(targetPath) || targetPath.hasPrefix(bundlePath) else { return }
            match.set(application)
        }
        guard let url = URL(string: "steam://rungameid/\(appID)") else {
            center.removeObserver(observer)
            finish(gameID: game.id)
            ConsoleToastManager.shared.post("Unable to Launch", "Steam could not create a launch link for \(game.title).", priority: .warning)
            return
        }
        guard workspace.open(url) else {
            center.removeObserver(observer)
            finish(gameID: game.id)
            UISoundManager.playBoundaryBump()
            ConsoleToastManager.shared.post("Unable to Launch", "Steam did not accept the launch request for \(game.displayTitle).", priority: .warning)
            return
        }
        Task { @MainActor [weak self, weak store] in
            for _ in 0..<30 {
                if match.get() != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            center.removeObserver(observer)
            guard let self else { return }
            guard let application = match.get() else {
                self.finish(gameID: game.id)
                ConsoleToastManager.shared.post("Steam Is Starting", "\(game.displayTitle) has been sent to Steam. Check Steam's download or install state.", symbol: "steam", priority: .normal)
                return
            }
            guard let store else { return }
            store.markGameLaunched(game.id)
            store.onConsoleExternalApplicationLaunched?(application, game.id, game.displayTitle)
        }
    }
}
