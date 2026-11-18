import AppKit
import Combine
import CryptoKit
import Foundation

enum WindowsStorefront: String, CaseIterable, Identifiable {
    case epic = "Epic Games"
    case gog = "GOG"
    var id: String { rawValue }
    var source: GameSource { self == .epic ? .epic : .gog }
    var bottleName: String { self == .epic ? "MetalOS-Epic" : "MetalOS-GOG" }
}

struct WindowsStoreGame: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var installedPath: String? = nil
    var isInstalled: Bool { installedPath != nil }
}

private struct StorefrontRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int64
        let digest: String?
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, size, digest; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case assets }
}

@MainActor
final class WindowsStorefrontRuntime: ObservableObject {
    @Published var selectedProvider: WindowsStorefront = .epic
    @Published private(set) var epicGames: [WindowsStoreGame] = []
    @Published private(set) var gogGames: [WindowsStoreGame] = []
    @Published private(set) var status = "Epic uses Legendary. GOG uses gogdl."
    @Published private(set) var isWorking = false
    @Published private(set) var epicConnected = false
    @Published private(set) var gogConnected = false

    func legendaryCLI(workspace: URL) -> URL {
        WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Tools/legendary/legendary")
    }
    func gogdlCLI(workspace: URL) -> URL {
        WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Tools/heroic-gogdl/.venv/bin/gogdl")
    }
    func gogAuthPath(workspace: URL) -> URL {
        WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("GOG/auth.json")
    }
    func gameRoot(_ provider: WindowsStorefront, workspace: URL) -> URL {
        WindowsRuntimeLayout.highballHome(in: workspace)
            .appendingPathComponent("bottles/\(provider.bottleName)/drive_c/Program Files/MetalOS/\(provider == .epic ? "Epic" : "GOG")", isDirectory: true)
    }

    func installLegendary(workspace: URL?) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        isWorking = true; defer { isWorking = false }
        do {
            status = "Checking the latest Legendary release…"
            let release = try await Self.fetchJSON(URL(string: "https://api.github.com/repos/legendary-gl/legendary/releases/latest")!, as: StorefrontRelease.self)
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x64"
            #endif
            guard let asset = release.assets.first(where: { $0.name == "legendary_macOS_\(architecture)" }),
                  asset.size > 100_000, asset.size < 100_000_000,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else {
                throw StudioError.message("Legendary has no matching macOS binary with a published SHA-256 checksum.")
            }
            let destination = legendaryCLI(workspace: workspace)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            status = "Downloading Legendary \(release.tagName)…"
            let (temporary, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("Legendary could not be downloaded.") }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst("sha256:".count)).lowercased() else { throw StudioError.message("Legendary’s download did not match its published SHA-256 checksum.") }
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            status = "Legendary \(release.tagName) is installed. Connect Epic, then refresh the library."
        } catch { status = "Could not install Legendary: \(error.localizedDescription)" }
    }

    func installGogdl(workspace: URL?, pythonPath: String) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        let python = URL(fileURLWithPath: pythonPath)
        guard FileManager.default.isExecutableFile(atPath: python.path) else { status = "Choose a working Python 3.10+ runtime before installing gogdl."; return }
        isWorking = true; defer { isWorking = false }
        do {
            let versionOutput = try await Self.run(python, ["--version"], cwd: WindowsRuntimeLayout.root(in: workspace))
            let versionParts = versionOutput.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard versionParts.count >= 2, versionParts[0] > 3 || (versionParts[0] == 3 && versionParts[1] >= 10) else {
                throw StudioError.message("gogdl requires Python 3.10 or newer. Select a newer Python runtime in MetalOS settings.")
            }
            let tools = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Tools", isDirectory: true)
            let repository = tools.appendingPathComponent("heroic-gogdl", isDirectory: true)
            let environment = repository.appendingPathComponent(".venv", isDirectory: true)
            let binary = environment.appendingPathComponent("bin/gogdl")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: repository.appendingPathComponent("pyproject.toml").path) {
                status = "Downloading gogdl source…"
                _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/git"), ["clone", "--depth", "1", "--recurse-submodules", "--shallow-submodules", "https://github.com/Heroic-Games-Launcher/heroic-gogdl.git", repository.path], cwd: tools)
            } else {
                status = "Updating gogdl source…"
                _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repository.path, "pull", "--ff-only"], cwd: tools)
                _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repository.path, "submodule", "update", "--init", "--recursive", "--depth", "1"], cwd: tools)
            }
            if !FileManager.default.isExecutableFile(atPath: environment.appendingPathComponent("bin/python").path) {
                status = "Creating gogdl’s isolated Python environment…"
                _ = try await Self.run(python, ["-m", "venv", environment.path], cwd: repository)
            }
            status = "Installing gogdl and its dependencies…"
            _ = try await Self.run(environment.appendingPathComponent("bin/python"), ["-m", "pip", "install", "--upgrade", "."], cwd: repository)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw StudioError.message("gogdl did not create its command line tool.") }
            status = "gogdl is ready. Connect GOG, then refresh the library."
        } catch { status = "Could not install gogdl: \(error.localizedDescription)" }
    }

    func epicLoginURL(workspace: URL?) -> URL? {
        guard let workspace else { status = "Choose a library folder first."; return nil }
        let cli = legendaryCLI(workspace: workspace)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { status = "Install Legendary first."; return nil }
        guard let url = URL(string: "https://legendary.gl/epiclogin") else { status = "Epic sign-in URL is unavailable."; return nil }
        status = "Sign in using MetalOS’s in-app browser."
        return url
    }

    func connectEpic(workspace: URL?) { _ = epicLoginURL(workspace: workspace) }

    func completeEpicLogin(code input: String, workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        let cli = legendaryCLI(workspace: workspace)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { status = "Install Legendary first."; return }
        guard let code = Self.authorizationCode(from: input), !code.isEmpty else {
            status = "Paste the authorizationCode value or the JSON/URL from Epic’s sign-in page."
            return
        }
        isWorking = true; defer { isWorking = false }
        do {
            status = "Completing Epic sign-in…"
            _ = try await Self.run(cli, ["auth", "--code", code], cwd: cli.deletingLastPathComponent())
            let output = try await Self.run(cli, ["status", "--json"], cwd: cli.deletingLastPathComponent(), discardStandardError: true)
            guard let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let account = value["account"] as? String,
                  !account.isEmpty, account != "<not logged in>" else {
                throw StudioError.message("Legendary did not confirm an Epic account. Check the code and try again.")
            }
            epicConnected = true
            await refreshEpicGames(workspace: workspace)
            status = "Connected to Epic as \(account). Loaded \(epicGames.count) games."
        } catch {
            epicConnected = false
            status = "Epic sign-in failed: \(error.localizedDescription)"
        }
    }

    func gogLoginURL() -> URL? {
        var components = URLComponents(string: "https://auth.gog.com/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "46899977096215655"),
            URLQueryItem(name: "redirect_uri", value: "https://embed.gog.com/on_login_success?origin=client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "client2")
        ]
        return components.url
    }

    func completeGOGLogin(code: String, workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        guard let authorizationCode = Self.authorizationCode(from: code), !authorizationCode.isEmpty else {
            status = "Paste the code or redirect URL from GOG’s sign-in page."
            return
        }
        isWorking = true; defer { isWorking = false }
        do {
            let auth = gogAuthPath(workspace: workspace)
            try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
            status = "Completing GOG sign-in…"
            var components = URLComponents(string: "https://auth.gog.com/token")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: Self.gogClientID),
                URLQueryItem(name: "client_secret", value: Self.gogClientSecret),
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "redirect_uri", value: Self.gogRedirectURI),
                URLQueryItem(name: "code", value: authorizationCode)
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let token = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  token["error"] == nil,
                  token["access_token"] as? String != nil,
                  token["refresh_token"] as? String != nil else {
                let detail = token["error_description"] as? String ?? token["message"] as? String
                throw StudioError.message(detail ?? "GOG rejected the sign-in code. Open sign-in again and use a fresh code.")
            }
            var credentials = token
            credentials["loginTime"] = Date().timeIntervalSince1970
            let stored: [String: Any] = [Self.gogClientID: credentials]
            let savedData = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
            try savedData.write(to: auth, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
            gogConnected = true
            status = "GOG account connected. Loading your games…"
            await refreshGOGGames(workspace: workspace)
            if gogGames.isEmpty { status = "GOG account connected. No games were returned for this account." }
            else { status = "Connected to GOG. Loaded \(gogGames.count) games." }
        } catch { gogConnected = false; status = "GOG sign-in failed: \(error.localizedDescription)" }
    }

    func refreshEpicGames(workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        let cli = legendaryCLI(workspace: workspace)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { status = "Install Legendary first."; return }
        isWorking = true; defer { isWorking = false }
        do {
            status = "Loading Epic library through Legendary…"
            let raw = try await Self.run(cli, ["list", "--platform", "Windows", "--json"], cwd: cli.deletingLastPathComponent(), discardStandardError: true)
            let rows = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] ?? []
            let installedRaw = try? await Self.run(cli, ["list-installed", "--json", "--show-dirs"], cwd: cli.deletingLastPathComponent(), discardStandardError: true)
            let installedRows = (try? JSONSerialization.jsonObject(with: Data((installedRaw ?? "[]").utf8))) as? [[String: Any]] ?? []
            let installed = Dictionary(uniqueKeysWithValues: installedRows.compactMap { row -> (String, String)? in
                guard let app = row["app_name"] as? String, let path = row["install_path"] as? String else { return nil }
                return (app, path)
            })
            epicGames = rows.compactMap { row in
                guard let id = row["app_name"] as? String, row["is_dlc"] as? Bool != true else { return nil }
                let title = row["app_title"] as? String ?? id
                return WindowsStoreGame(id: id, title: title, installedPath: installed[id])
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            status = "Loaded \(epicGames.count) Epic games."
        } catch { status = "Could not load Epic games: \(error.localizedDescription)" }
    }

    func refreshGOGGames(workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        let authPath = gogAuthPath(workspace: workspace)
        guard let token = try? await Self.gogAccessToken(at: authPath) else {
            gogConnected = false
            status = "Connect a GOG account first."; return
        }
        gogConnected = true
        isWorking = true; defer { isWorking = false }
        do {
            status = "Loading GOG owned games…"
            var request = URLRequest(url: URL(string: "https://embed.gog.com/user/data/games")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["owned"] as? [Int] else { throw StudioError.message("GOG did not return the owned game list.") }
            let roots = gameRoot(.gog, workspace: workspace)
            let installed = Self.gogInstalledDirectories(in: roots)
            gogGames = await withTaskGroup(of: WindowsStoreGame?.self) { group in
                var remaining = ids.makeIterator()
                func add(_ id: Int) {
                    group.addTask {
                        guard let url = URL(string: "https://api.gog.com/products/\(id)") else { return nil }
                        var productRequest = URLRequest(url: url)
                        productRequest.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
                        guard let (productData, productResponse) = try? await URLSession.shared.data(for: productRequest),
                              (productResponse as? HTTPURLResponse)?.statusCode == 200,
                              let product = try? JSONSerialization.jsonObject(with: productData) as? [String: Any],
                              let title = product["title"] as? String else { return nil }
                        return WindowsStoreGame(id: String(id), title: title, installedPath: installed[String(id)])
                    }
                }
                var games: [WindowsStoreGame] = []
                for _ in 0..<min(8, ids.count) { if let id = remaining.next() { add(id) } }
                while let game = await group.next() {
                    if let game { games.append(game) }
                    if let id = remaining.next() { add(id) }
                }
                return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            status = "Loaded \(gogGames.count) GOG games."
        } catch { status = "Could not load GOG games: \(error.localizedDescription)" }
    }

    nonisolated private static let gogClientID = "46899977096215655"
    nonisolated private static let gogClientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    nonisolated private static let gogRedirectURI = "https://embed.gog.com/on_login_success?origin=client"
    nonisolated private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private nonisolated static func authorizationCode(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" || $0.name == "authorizationCode" })?.value {
            return code.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["authorizationCode"] as? String ?? object["code"] as? String {
            return code.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private nonisolated static func gogAccessToken(at authPath: URL) async throws -> String {
        let data = try Data(contentsOf: authPath)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              var account = object[gogClientID],
              let refreshToken = account["refresh_token"] as? String else { throw StudioError.message("Connect your GOG account first.") }
        let loginTime = account["loginTime"] as? Double ?? 0
        let expiresIn = account["expires_in"] as? Double ?? 0
        if Date().timeIntervalSince1970 >= loginTime + expiresIn - 60 {
            var components = URLComponents(string: "https://auth.gog.com/token")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: gogClientID),
                URLQueryItem(name: "client_secret", value: gogClientSecret),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "without_new_session", value: "1")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (freshData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  var fresh = (try? JSONSerialization.jsonObject(with: freshData)) as? [String: Any],
                  fresh["access_token"] as? String != nil,
                  fresh["refresh_token"] as? String != nil else { throw StudioError.message("GOG sign-in expired. Reconnect your account.") }
            fresh["loginTime"] = Date().timeIntervalSince1970
            account = fresh
            let saved = try JSONSerialization.data(withJSONObject: [gogClientID: account], options: [.sortedKeys])
            try saved.write(to: authPath, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath.path)
        }
        guard let token = account["access_token"] as? String else { throw StudioError.message("GOG access token is missing. Reconnect your account.") }
        return token
    }

    func install(_ game: WindowsStoreGame, provider: WindowsStorefront, workspace: URL?, wineInstaller: WindowsClientInstaller) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        do {
            status = "Preparing Highball’s \(provider.rawValue) bottle…"
            _ = try await wineInstaller.prepareStoreBottle(name: provider.bottleName, workspace: workspace)
            let root = gameRoot(provider, workspace: workspace)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if provider == .epic {
                let cli = legendaryCLI(workspace: workspace)
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw StudioError.message("Install Legendary first.") }
                status = "Installing \(game.title) through Legendary…"
                _ = try await Self.run(cli, ["install", game.id, "--platform", "Windows", "--base-path", root.path, "--skip-sdl"], cwd: cli.deletingLastPathComponent())
                await refreshEpicGames(workspace: workspace)
            } else {
                let cli = gogdlCLI(workspace: workspace)
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw StudioError.message("Install gogdl first.") }
                let auth = gogAuthPath(workspace: workspace)
                let path = root.appendingPathComponent(game.id, isDirectory: true)
                status = "Installing \(game.title) through gogdl…"
                _ = try await Self.run(cli, ["--auth-config-path", auth.path, "download", game.id, "--path", path.path, "--platform", "windows"], cwd: cli.deletingLastPathComponent())
                await refreshGOGGames(workspace: workspace)
            }
            status = "\(game.title) is installed and added to the library."
        } catch { status = "Could not install \(game.title): \(error.localizedDescription)" }
    }

    private static func gogInstalledDirectories(in root: URL) -> [String: String] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [:] }
        var output: [String: String] = [:]
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("goggame-") && file.pathExtension == "info" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["rootGameId"] as? Int else { continue }
                output[String(id)] = folder.path
            }
        }
        return output
    }

    private static func fetchJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url); request.setValue("MetalOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.message("The provider did not return a successful response.") }
        return try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func run(_ executable: URL, _ arguments: [String], cwd: URL, discardStandardError: Bool = false) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(); let output = Pipe()
            process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = cwd
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output
            process.standardError = discardStandardError ? FileHandle.nullDevice : output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw StudioError.message(String(decoding: data.suffix(6000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

