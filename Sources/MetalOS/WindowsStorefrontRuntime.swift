import AppKit
import Combine
import CryptoKit
import Foundation

enum WindowsStorefront: String, Codable, CaseIterable, Identifiable {
    case epic = "Epic Games"
    case gog = "GOG"
    var id: String { rawValue }
    var source: GameSource { self == .epic ? .epic : .gog }
}

struct WindowsStoreGame: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var installedPath: String? = nil
    var executableIconPath: String? = nil
    var isInstalled: Bool { installedPath != nil }
}

struct StorefrontNotification: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
    let progress: Double?
    let isActive: Bool
}

private struct PausedStoreInstall: Codable {
    let gameID: String
    let title: String
    let provider: WindowsStorefront
    let workspacePath: String
    let progress: Double?
    let progressLabel: String
}

private final class StoreInstallOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    func data() -> Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class StoreInstallControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var paused = false
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldPause = paused
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { process.terminate() }
        else if shouldPause { _ = process.suspend() }
    }

    func pause() {
        lock.lock()
        paused = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { _ = process.suspend() }
    }

    func resume() {
        lock.lock()
        paused = false
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { _ = process.resume() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let wasPaused = paused
        paused = false
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            if wasPaused { _ = process.resume() }
            process.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
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
    @Published private(set) var epicPrivacyAcceptanceRequired = false
    @Published private(set) var epicReauthenticationRequired = false
    @Published private(set) var gogConnected = false
    @Published private(set) var gogReauthenticationRequired = false
    @Published private(set) var legendaryInstalled = false
    @Published private(set) var gogdlInstalled = false
    @Published private(set) var isInstallingGame = false
    @Published private(set) var isInstallPaused = false
    @Published private(set) var installGameID: String?
    @Published private(set) var installProvider: WindowsStorefront?
    @Published private(set) var installProgress: Double?
    @Published private(set) var installProgressLabel = ""
    @Published private(set) var notification: StorefrontNotification?
    private var installOutputRemainder = ""
    private var installControl: StoreInstallControl?
    private var activeInstallNotificationID: UUID?
    private var restoredInstallTitle: String?
    private let pausedInstallKey = "WindowsStorefrontRuntime.pausedInstall.v1"

    init() {
        guard let data = UserDefaults.standard.data(forKey: pausedInstallKey),
              let saved = try? JSONDecoder().decode(PausedStoreInstall.self, from: data) else { return }
        isInstallingGame = true
        isInstallPaused = true
        installGameID = saved.gameID
        installProvider = saved.provider
        installProgress = saved.progress
        installProgressLabel = saved.progressLabel.hasPrefix("Paused · ") ? saved.progressLabel : "Paused · " + saved.progressLabel
        restoredInstallTitle = saved.title
        status = "\(saved.title) is paused. Resume to continue from downloaded files."
        notification = StorefrontNotification(id: UUID(), title: "Download paused", message: installProgressLabel, progress: installProgress, isActive: true)
    }

    func toolInstalled(for provider: WindowsStorefront) -> Bool {
        provider == .epic ? legendaryInstalled : gogdlInstalled
    }

    func isConnected(to provider: WindowsStorefront) -> Bool {
        provider == .epic ? epicConnected : gogConnected
    }

    func signInButtonTitle(for provider: WindowsStorefront) -> String {
        let reconnect = provider == .epic ? epicReauthenticationRequired : gogReauthenticationRequired
        if reconnect { return "Reconnect \(provider == .epic ? "Epic" : "GOG")" }
        return isConnected(to: provider) ? "Connected" : "Sign in"
    }

    func canStartSignIn(for provider: WindowsStorefront) -> Bool {
        let reconnect = provider == .epic ? epicReauthenticationRequired : gogReauthenticationRequired
        return !isWorking && (!isConnected(to: provider) || reconnect)
    }

    func isInstalling(_ game: WindowsStoreGame, provider: WindowsStorefront) -> Bool {
        isInstallingGame && installGameID == game.id && installProvider == provider
    }

    func pauseInstall() {
        guard isInstallingGame, !isInstallPaused else { return }
        installControl?.pause()
        isInstallPaused = true
        status = "Installation paused."
        if !installProgressLabel.hasPrefix("Paused") { installProgressLabel = "Paused · " + installProgressLabel }
        persistPausedInstall()
        postNotification(title: "Download paused", message: installProgressLabel, progress: installProgress, active: true, reuseActiveID: true)
    }

    func resumeInstall() {
        guard isInstallingGame, isInstallPaused else { return }
        isInstallPaused = false
        status = "Resuming installation…"
        if installProgressLabel.hasPrefix("Paused · ") {
            installProgressLabel = String(installProgressLabel.dropFirst("Paused · ".count))
        }
        if let installControl {
            installControl.resume()
        } else if let saved = loadPausedInstall() {
            Task { await install(WindowsStoreGame(id: saved.gameID, title: saved.title), provider: saved.provider, workspace: URL(fileURLWithPath: saved.workspacePath, isDirectory: true)) }
        } else {
            isInstallingGame = false
            installGameID = nil
            installProvider = nil
        }
        postNotification(title: "Download resumed", message: installProgressLabel, progress: installProgress, active: true, reuseActiveID: true)
    }

    func cancelInstall() {
        guard isInstallingGame else { return }
        let title = installGameTitle
        UserDefaults.standard.removeObject(forKey: pausedInstallKey)
        isInstallPaused = false
        installProgressLabel = "Stopping installation…"
        status = "Stopping installation…"
        installControl?.cancel()
        if installControl == nil {
            isInstallingGame = false
            installGameID = nil
            installProvider = nil
            installProgress = nil
            restoredInstallTitle = nil
            activeWorkspacePath = nil
            status = "Installation stopped. Start it again to resume from downloaded files."
        }
        postNotification(title: "Stopping download", message: "\(title) is stopping.", progress: nil, active: false)
    }

    var installGameTitle: String {
        let games = installProvider == .epic ? epicGames : gogGames
        return games.first(where: { $0.id == installGameID })?.title ?? restoredInstallTitle ?? "Game installation"
    }

    private func loadPausedInstall() -> PausedStoreInstall? {
        guard let data = UserDefaults.standard.data(forKey: pausedInstallKey) else { return nil }
        return try? JSONDecoder().decode(PausedStoreInstall.self, from: data)
    }

    private func persistPausedInstall() {
        guard let installGameID, let installProvider, let workspacePath = workspacePathForInstall,
              let data = try? JSONEncoder().encode(PausedStoreInstall(gameID: installGameID, title: installGameTitle,
                                                                     provider: installProvider, workspacePath: workspacePath,
                                                                     progress: installProgress, progressLabel: installProgressLabel)) else { return }
        UserDefaults.standard.set(data, forKey: pausedInstallKey)
    }

    private var workspacePathForInstall: String? { loadPausedInstall()?.workspacePath ?? activeWorkspacePath }
    private var activeWorkspacePath: String?

    func dismissNotification(_ id: UUID) {
        guard notification?.id == id, notification?.isActive != true else { return }
        notification = nil
    }

    private func postNotification(title: String, message: String, progress: Double?, active: Bool, reuseActiveID: Bool = false) {
        let id = reuseActiveID ? (activeInstallNotificationID ?? UUID()) : UUID()
        if active { activeInstallNotificationID = id }
        notification = StorefrontNotification(id: id, title: title, message: message, progress: progress, isActive: active)
        if !active { activeInstallNotificationID = nil }
    }

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
        WindowsRuntimeLayout.root(in: workspace)
            .appendingPathComponent("Games/\(provider == .epic ? "Epic" : "GOG")", isDirectory: true)
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
            legendaryInstalled = true
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
            gogdlInstalled = true
            status = "gogdl is ready. Connect GOG, then refresh the library."
        } catch { status = "Could not install gogdl: \(error.localizedDescription)" }
    }

    func epicLoginURL(workspace: URL?) -> URL? {
        guard let workspace else { status = "Choose a library folder first."; return nil }
        let cli = legendaryCLI(workspace: workspace)
        legendaryInstalled = FileManager.default.isExecutableFile(atPath: cli.path)
        guard legendaryInstalled else { status = "Install Legendary first."; return nil }
        guard let url = URL(string: "https://legendary.gl/epiclogin") else { status = "Epic sign-in URL is unavailable."; return nil }
        epicPrivacyAcceptanceRequired = false
        status = "Sign in using MetalOS’s in-app browser."
        return url
    }

    func openEpicAccountSignIn() {
        guard let url = URL(string: "https://www.epicgames.com/id/login") else { return }
        NSWorkspace.shared.open(url)
    }

    func connectEpic(workspace: URL?) { _ = epicLoginURL(workspace: workspace) }

    func completeEpicLogin(code input: String, workspace: URL?) async {
        if Self.requiresEpicPrivacyAcceptance(input) {
            epicPrivacyAcceptanceRequired = true
            status = "Epic needs you to review and accept its privacy policy. Open Epic in your browser, finish that step, then start sign-in again."
            return
        }
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
            epicPrivacyAcceptanceRequired = false
            epicReauthenticationRequired = false
            await refreshEpicGames(workspace: workspace)
            status = "Connected to Epic as \(account). Loaded \(epicGames.count) games."
        } catch {
            epicConnected = false
            if Self.requiresEpicPrivacyAcceptance(error.localizedDescription) {
                epicPrivacyAcceptanceRequired = true
                status = "Epic needs you to review and accept its privacy policy. Open Epic in your browser, finish that step, then start sign-in again."
            } else if Self.isEpicSessionReuseFailure(error.localizedDescription) {
                epicReauthenticationRequired = true
                status = "Epic could not resume its saved login. Choose Reconnect Epic, finish sign-in, then retry."
            } else {
                status = "Epic sign-in failed: \(error.localizedDescription)"
            }
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
            gogReauthenticationRequired = false
            status = "GOG account connected. Loading your games…"
            await refreshGOGGames(workspace: workspace)
            if gogGames.isEmpty { status = "GOG account connected. No games were returned for this account." }
            else { status = "Connected to GOG. Loaded \(gogGames.count) games." }
        } catch { gogConnected = false; status = "GOG sign-in failed: \(error.localizedDescription)" }
    }

    func refreshEpicGames(workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        let cli = legendaryCLI(workspace: workspace)
        legendaryInstalled = FileManager.default.isExecutableFile(atPath: cli.path)
        guard legendaryInstalled else { epicConnected = false; epicGames = []; status = "Install Legendary first."; return }
        isWorking = true; defer { isWorking = false }
        do {
            let accountOutput = try await Self.run(cli, ["status", "--json"], cwd: cli.deletingLastPathComponent(), discardStandardError: true)
            let accountStatus = try JSONSerialization.jsonObject(with: Data(accountOutput.utf8)) as? [String: Any]
            let account = accountStatus?["account"] as? String
            epicConnected = account.map { !$0.isEmpty && $0 != "<not logged in>" } ?? false
            guard epicConnected else {
                epicReauthenticationRequired = true
                epicGames = []
                status = "Reconnect Epic to load your games."
                return
            }
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
                let icon = WindowsExecutableIcon.cachedPath(gameID: id, provider: .epic, workspace: workspace).path
                return WindowsStoreGame(id: id, title: title, installedPath: installed[id], executableIconPath: FileManager.default.fileExists(atPath: icon) ? icon : nil)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            epicReauthenticationRequired = false
            status = "Loaded \(epicGames.count) Epic games."
        } catch {
            if Self.isEpicSessionReuseFailure(error.localizedDescription) {
                epicConnected = false
                epicReauthenticationRequired = true
                status = "Epic could not resume its saved login. Choose Reconnect Epic, finish sign-in, then retry."
            } else {
                status = "Could not load Epic games: \(error.localizedDescription)"
            }
        }
    }

    func refreshGOGGames(workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        gogdlInstalled = FileManager.default.isExecutableFile(atPath: gogdlCLI(workspace: workspace).path)
        let authPath = gogAuthPath(workspace: workspace)
        guard let token = try? await Self.gogAccessToken(at: authPath) else {
            gogConnected = false
            gogReauthenticationRequired = true
            status = "Reconnect GOG to load its games."; return
        }
        gogConnected = true
        gogReauthenticationRequired = false
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
                        let gameID = String(id)
                        let icon = WindowsExecutableIcon.cachedPath(gameID: gameID, provider: .gog, workspace: workspace).path
                        return WindowsStoreGame(id: gameID, title: title, installedPath: installed[gameID], executableIconPath: FileManager.default.fileExists(atPath: icon) ? icon : nil)
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

    private nonisolated static func requiresEpicPrivacyAcceptance(_ input: String) -> Bool {
        if input.contains("errors.com.epicgames.oauth.corrective_action_required") && input.contains("PRIVACY_POLICY_ACCEPTANCE") {
            return true
        }
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = object["metadata"] as? [String: Any] else { return false }
        return object["errorCode"] as? String == "errors.com.epicgames.oauth.corrective_action_required"
            && metadata["correctiveAction"] as? String == "PRIVACY_POLICY_ACCEPTANCE"
    }

    private nonisolated static func isEpicSessionReuseFailure(_ input: String) -> Bool {
        let value = input.lowercased()
        let triedSession = value.contains("trying to re-use existing login session")
            || value.contains("trying to reuse existing login session")
        guard triedSession else { return false }
        return value.contains("stored credentials are no longer valid")
            || value.contains("resuming failed due to invalid credentials")
            || value.contains("login failed, cannot continue")
            || value.contains("invalidcredentials")
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

    func install(_ game: WindowsStoreGame, provider: WindowsStorefront, workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        guard !isWorking else { return }
        let savedCheckpoint = loadPausedInstall()
        let isResuming = savedCheckpoint?.gameID == game.id && savedCheckpoint?.provider == provider
        isWorking = true; defer { isWorking = false }
        isInstallingGame = true
        isInstallPaused = false
        installGameID = game.id
        installProvider = provider
        restoredInstallTitle = game.title
        activeWorkspacePath = workspace.path
        UserDefaults.standard.removeObject(forKey: pausedInstallKey)
        let control = StoreInstallControl()
        installControl = control
        defer {
            isInstallingGame = false
            isInstallPaused = false
            installGameID = nil
            installProvider = nil
            installControl = nil
            restoredInstallTitle = nil
            activeWorkspacePath = nil
        }
        installProgress = isResuming ? savedCheckpoint?.progress : nil
        installProgressLabel = isResuming ? (savedCheckpoint?.progressLabel.replacingOccurrences(of: "Paused · ", with: "") ?? "Resuming download…") : "Preparing download…"
        installOutputRemainder = ""
        postNotification(title: "Download started", message: game.title, progress: nil, active: true)
        do {
            let root = gameRoot(provider, workspace: workspace)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if provider == .epic {
                let cli = legendaryCLI(workspace: workspace)
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw StudioError.message("Install Legendary first.") }
                status = "Installing \(game.title) through Legendary…"
                // Legendary is run without interactive stdin, like Heroic's managed install
                // process. `-y` is required so its confirmation prompt cannot abort after
                // the manifest has been parsed.
                _ = try await Self.runWithProgress(cli, ["install", game.id, "--platform", "Windows", "--base-path", root.path, "--skip-sdl", "-y"], cwd: cli.deletingLastPathComponent(), control: control) { [weak self] chunk in
                    self?.consumeInstallOutput(chunk)
                }
                await refreshEpicGames(workspace: workspace)
                await extractInstalledIcon(game.id, provider: provider, workspace: workspace)
            } else {
                let cli = gogdlCLI(workspace: workspace)
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw StudioError.message("Install gogdl first.") }
                let auth = gogAuthPath(workspace: workspace)
                let path = root.appendingPathComponent(game.id, isDirectory: true)
                status = "Installing \(game.title) through gogdl…"
                _ = try await Self.runWithProgress(cli, ["--auth-config-path", auth.path, "download", game.id, "--path", path.path, "--platform", "windows"], cwd: cli.deletingLastPathComponent(), control: control) { [weak self] chunk in
                    self?.consumeInstallOutput(chunk)
                }
                await refreshGOGGames(workspace: workspace)
                await extractInstalledIcon(game.id, provider: provider, workspace: workspace)
            }
            installProgress = 1
            installProgressLabel = "Finishing installation…"
            status = "\(game.title) is installed and added to the library."
            postNotification(title: "Installation complete", message: game.title, progress: 1, active: false)
        } catch {
            installProgress = nil
            if control.isCancelled {
                status = "Installation stopped. Start it again to resume from downloaded files."
                postNotification(title: "Download stopped", message: "\(game.title) can resume when you install it again.", progress: nil, active: false)
            } else if provider == .epic && Self.isEpicSessionReuseFailure(error.localizedDescription) {
                epicConnected = false
                epicReauthenticationRequired = true
                status = "Epic could not resume its saved login. Choose Reconnect Epic, finish sign-in, then retry the install."
            } else if provider == .gog && error.localizedDescription.localizedCaseInsensitiveContains("sign-in expired") {
                gogConnected = false
                gogReauthenticationRequired = true
                status = "GOG sign-in expired. Choose Reconnect GOG, then retry the install."
            } else {
                status = "Could not install \(game.title): \(error.localizedDescription)"
            }
            if !control.isCancelled { postNotification(title: "Installation failed", message: status, progress: nil, active: false) }
            UserDefaults.standard.removeObject(forKey: pausedInstallKey)
        }
    }

    private func extractInstalledIcon(_ gameID: String, provider: WindowsStorefront, workspace: URL) async {
        let games = provider == .epic ? epicGames : gogGames
        guard let index = games.firstIndex(where: { $0.id == gameID }), let path = await WindowsExecutableIcon.extract(game: games[index], provider: provider, workspace: workspace) else { return }
        let updated = WindowsStoreGame(id: games[index].id, title: games[index].title, installedPath: games[index].installedPath, executableIconPath: path)
        if provider == .epic { epicGames[index] = updated } else { gogGames[index] = updated }
    }

    func uninstall(_ game: WindowsStoreGame, provider: WindowsStorefront, workspace: URL?) async {
        guard let workspace else { status = "Choose a library folder first."; return }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            status = "Uninstalling \(game.title)…"
            postNotification(title: "Uninstalling game", message: game.title, progress: nil, active: false)
            if provider == .epic {
                let cli = legendaryCLI(workspace: workspace)
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw StudioError.message("Legendary is missing.") }
                _ = try await Self.run(cli, ["uninstall", "-y", game.id], cwd: cli.deletingLastPathComponent())
                await refreshEpicGames(workspace: workspace)
            } else {
                let root = gameRoot(.gog, workspace: workspace).standardizedFileURL
                guard let installedPath = game.installedPath else { throw StudioError.message("GOG’s install path is missing.") }
                let target = URL(fileURLWithPath: installedPath, isDirectory: true).standardizedFileURL
                let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard target.path.hasPrefix(rootPrefix), target.path != root.path else {
                    throw StudioError.message("MetalOS can only uninstall GOG games from its managed GOG library folder.")
                }
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.removeItem(at: target)
                }.value
                await refreshGOGGames(workspace: workspace)
            }
            status = "\(game.title) was uninstalled."
            postNotification(title: "Game uninstalled", message: game.title, progress: nil, active: false)
        } catch {
            status = "Could not uninstall \(game.title): \(error.localizedDescription)"
            postNotification(title: "Uninstall failed", message: status, progress: nil, active: false)
        }
    }

    private func consumeInstallOutput(_ chunk: String) {
        installOutputRemainder = String((installOutputRemainder + chunk).suffix(1000))
        guard let expression = try? NSRegularExpression(pattern: "([0-9]{1,3}(?:\\.[0-9]+)?)%") else { return }
        let range = NSRange(installOutputRemainder.startIndex..., in: installOutputRemainder)
        guard let match = expression.matches(in: installOutputRemainder, range: range).last,
              let valueRange = Range(match.range(at: 1), in: installOutputRemainder),
              let percent = Double(installOutputRemainder[valueRange]), (0...100).contains(percent) else {
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, installProgress == nil {
                installProgressLabel = "Downloading game files…"
            }
            return
        }
        installProgress = percent / 100
        installProgressLabel = "Downloading game files · \(Int(percent.rounded()))%"
        postNotification(title: "Downloading \(installGameTitle)", message: installProgressLabel, progress: installProgress, active: true, reuseActiveID: true)
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

    private nonisolated static func runWithProgress(_ executable: URL, _ arguments: [String], cwd: URL, control: StoreInstallControl,
                                                     onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let buffer = StoreInstallOutput()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            control.attach(process)
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                buffer.append(data)
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in onOutput(chunk) }
            }
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            let remaining = output.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty { buffer.append(remaining) }
            let data = buffer.data()
            guard process.terminationStatus == 0 else {
                let details = String(decoding: data.suffix(6000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = "Installer exited with status \(process.terminationStatus)."
                throw StudioError.message(details.isEmpty ? exit : "\(exit)\n\(details)")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
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

