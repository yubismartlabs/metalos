import Foundation

/// Reads local manifests only. Does not authenticate, download games, or change another launcher's files.
struct GameDiscovery: Sendable {
    static let managerBundleIDs: Set<String> = ["com.codeweavers.CrossOver", "com.heroicgameslauncher.hgl", "com.valvesoftware.steam", "com.varyform.nxplay", "org.nxnative.NSPortBuilder"]
    func scan(roots: [String]) async -> DiscoveryResult {
        await Task.detached(priority: .utility) { Self.scanLocal(roots: roots) }.value
    }

    private static func scanLocal(roots: [String]) -> DiscoveryResult {
        let fm = FileManager.default
        var result = DiscoveryResult()
        var seen = Set<String>()
        for path in roots {
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL
            guard fm.fileExists(atPath: root.path) else {
                result.warnings.append("Game library folder is unavailable: \(root.path)")
                continue
            }
            if root.pathExtension.lowercased() == "app" { continue }
            let switchResult = SwitchGameDiscovery.scan(root: root)
            result.games += switchResult.games.filter { seen.insert($0.id).inserted }
            result.warnings += switchResult.warnings
        }
        result.games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }

    static func steamLibraryPaths(_ text: String) -> [String] {
        pairs(in: text).compactMap { key, value in
            if key.lowercased() == "path" || (Int(key) != nil && value.hasPrefix("/")) { return value }
            return nil
        }
    }

    static func steamGame(manifest: String, library: URL) -> Game? {
        let fields = Dictionary(pairs(in: manifest), uniquingKeysWith: { first, _ in first })
        guard let appID = fields["appid"], UInt64(appID) != nil,
              let name = fields["name"], !name.isEmpty,
              let directory = fields["installdir"], !directory.isEmpty,
              !directory.contains("/"), !directory.contains("\\"), directory != ".", directory != ".." else { return nil }
        return Game(id: "steam:\(appID)", title: name, source: .steam, launchURL: "steam://rungameid/\(appID)", installPath: library.appendingPathComponent("steamapps/common").appendingPathComponent(directory).path)
    }

    static func windowsSteamGames(in workspace: URL) -> [Game] {
        let root = WindowsRuntimeLayout.root(in: workspace)
        let steamRoots = [
            root.appendingPathComponent("HighballData/bottles/MetalOS-Steam/drive_c/Program Files (x86)/Steam", isDirectory: true),
            WindowsRuntimeLayout.bottle("Steam", in: workspace)
                .appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam", isDirectory: true)
        ]
        var seen = Set<String>()
        return steamRoots.flatMap { steamRoot -> [Game] in
            let steamApps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: steamApps, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            return files.filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                .compactMap { url -> Game? in
                    guard let manifest = try? String(contentsOf: url, encoding: .utf8),
                          var game = steamGame(manifest: manifest, library: steamRoot), game.isAvailable,
                          seen.insert(game.id).inserted else { return nil }
                    game.launchURL = "metalos-windows://steam/\(game.id.dropFirst("steam:".count))"
                    return game
                }
        }
    }

    static func windowsClientLaunchers(in workspace: URL) -> [Game] {
        let home = WindowsRuntimeLayout.highballHome(in: workspace)
        let clients: [(String, String, GameSource, String)] = [
            ("Steam", "bottles/MetalOS-Steam/drive_c/Program Files (x86)/Steam/steam.exe", .steam, "steam"),
            ("Rockstar Games Launcher", "bottles/MetalOS-Rockstar/drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe", .windows, "rockstar")
        ]
        return clients.compactMap { title, relativePath, source, client in
            let executable = home.appendingPathComponent(relativePath)
            guard FileManager.default.isReadableFile(atPath: executable.path) else { return nil }
            return Game(id: "windows-client:highball:\(client)", title: title, source: source,
                        launchURL: "metalos-highball://\(client)", installPath: executable.path)
        }
    }

    private static func pairs(in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*"((?:\\.|[^"\\])*)""#) else { return [] }
        let source = text as NSString
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        }
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            (unescape(source.substring(with: $0.range(at: 1))), unescape(source.substring(with: $0.range(at: 2))))
        }
    }

    static func appGame(at app: URL, allowUncategorized: Bool) -> Game? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let category = plist["LSApplicationCategoryType"] as? String ?? ""
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let isNX = bundleID.range(of: #"^org\.nxnative\.[0-9a-fA-F]{16}$"#, options: .regularExpression) != nil
        let isCrossOver = app.path.localizedCaseInsensitiveContains("/CrossOver/") || bundleID.localizedCaseInsensitiveContains("codeweavers.crossover")
        let isHeroic = bundleID.hasPrefix("com.heroicgameslauncher.shortcut")
        let isGame = category == "public.app-category.games" || category.hasSuffix("-games")
        // CrossOver itself is an application manager, not a game.
        if managerBundleIDs.contains(bundleID) { return nil }
        guard allowUncategorized || isGame || isNX || isCrossOver || isHeroic else { return nil }
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        let source: GameSource = isNX ? .nxnative : isCrossOver ? .crossover : isHeroic ? .heroic : FileManager.default.fileExists(atPath: receipt.path) ? .appStore : .native
        let title = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
        return Game(id: "app:\(app.standardizedFileURL.path)", title: title, source: source, launchURL: app.absoluteString, installPath: app.path, titleID: isNX ? String(bundleID.suffix(16)).uppercased() : nil, isGameApp: isGame || isNX || isCrossOver || isHeroic)
    }

    private static func heroicGames(home: URL, warnings: inout [String]) -> [Game] {
        var games: [Game] = []
        let configs = [home.appendingPathComponent("Library/Application Support/heroic"), home.appendingPathComponent(".config/heroic")]
        var manifests: [(URL, String)] = configs.flatMap { root in
            [(root.appendingPathComponent("legendaryConfig/legendary/installed.json"), "legendary"),
             (root.appendingPathComponent("gog_store/installed.json"), "gog"),
             (root.appendingPathComponent("nile_config/installed.json"), "nile")]
        }
        manifests.append((home.appendingPathComponent(".config/legendary/installed.json"), "legendary"))
        for (file, runner) in manifests where FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                let json = try JSONSerialization.jsonObject(with: data)
                games += heroicInstalled(json, runner: runner)
            } catch { warnings.append("Could not read Heroic manifest \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return games
    }

    static func heroicInstalled(_ json: Any, runner: String) -> [Game] {
        let rows: [(String, [String: Any])]
        if let object = json as? [String: Any], let installed = object["installed"] {
            return heroicInstalled(installed, runner: runner)
        } else if let array = json as? [[String: Any]] {
            rows = array.map { (($0["app_name"] as? String) ?? ($0["appName"] as? String) ?? ($0["id"] as? String) ?? "", $0) }
        } else if let object = json as? [String: [String: Any]] {
            rows = object.map { ($0.key, $0.value) }
        } else { return [] }
        return rows.compactMap { key, entry in
            guard entry["is_dlc"] as? Bool != true,
                  let path = entry["install_path"] as? String ?? entry["installPath"] as? String,
                  !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            let appName = entry["app_name"] as? String ?? entry["appName"] as? String ?? key
            guard !appName.isEmpty else { return nil }
            let title = entry["title"] as? String ?? entry["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
            var url = URLComponents()
            url.scheme = "heroic"; url.host = "launch"
            url.queryItems = [URLQueryItem(name: "appName", value: appName), URLQueryItem(name: "runner", value: runner)]
            guard let launchURL = url.string else { return nil }
            return Game(id: "heroic:\(runner):\(appName)", title: title, source: .heroic, launchURL: launchURL, installPath: path)
        }
    }
}
