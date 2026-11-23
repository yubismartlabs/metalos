import AVFoundation
import AppKit
import Combine
import CryptoKit
import SwiftUI
import WebKit

struct ConsoleLocalVideo: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    var thumbnailPath: String?
    var duration: TimeInterval = 0
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct ConsoleMediaApp: Identifiable, Hashable, Sendable {
    enum LaunchTarget: Hashable, Sendable {
        case localLibrary
        case web(URL)
        case native(bundleID: String, fallback: URL)
        case appBundle(URL)
        case appManager
    }

    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let target: LaunchTarget
    var isCustom = false

    static let curated: [ConsoleMediaApp] = [
        .init(id: "youtube", name: "YouTube", subtitle: "Videos, channels and playlists", symbol: "play.rectangle.fill", colors: [Color(red: 0.9, green: 0.08, blue: 0.12), Color(red: 0.35, green: 0.02, blue: 0.06)], target: .web(URL(string: "https://www.youtube.com/tv")!)),
        .init(id: "local", name: "Local Media", subtitle: "Your movies and videos", symbol: "film.fill", colors: [Color(red: 0.22, green: 0.42, blue: 0.79), Color(red: 0.08, green: 0.13, blue: 0.34)], target: .localLibrary),
        .init(id: "appletv", name: "Apple TV", subtitle: "Continue watching", symbol: "tv.fill", colors: [Color(red: 0.40, green: 0.36, blue: 0.76), Color(red: 0.08, green: 0.10, blue: 0.24)], target: .native(bundleID: "com.apple.TV", fallback: URL(string: "https://tv.apple.com")!)),
        .init(id: "spotify", name: "Spotify", subtitle: "Music for every moment", symbol: "waveform", colors: [Color(red: 0.12, green: 0.76, blue: 0.38), Color(red: 0.03, green: 0.22, blue: 0.12)], target: .native(bundleID: "com.spotify.client", fallback: URL(string: "https://open.spotify.com")!)),
        .init(id: "netflix", name: "Netflix", subtitle: "Series and films", symbol: "n.square.fill", colors: [Color(red: 0.85, green: 0.04, blue: 0.08), Color(red: 0.22, green: 0.02, blue: 0.04)], target: .web(URL(string: "https://www.netflix.com")!)),
        .init(id: "disney", name: "Disney+", subtitle: "Stories worth streaming", symbol: "sparkles", colors: [Color(red: 0.12, green: 0.42, blue: 0.9), Color(red: 0.03, green: 0.12, blue: 0.34)], target: .web(URL(string: "https://www.disneyplus.com")!)),
        .init(id: "plex", name: "Plex", subtitle: "Your personal media", symbol: "play.tv.fill", colors: [Color(red: 0.98, green: 0.67, blue: 0.12), Color(red: 0.31, green: 0.13, blue: 0.02)], target: .web(URL(string: "https://app.plex.tv")!)),
        .init(id: "all", name: "All Media Apps", subtitle: "Manage your media destinations", symbol: "square.grid.2x2.fill", colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)], target: .appManager)
    ]
}

struct ConsoleMediaShelfItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var thumbnailPath: String? = nil
    var video: ConsoleLocalVideo? = nil
    var launchURL: URL? = nil
    var isProgressCard = false
}

@MainActor
final class MediaLaunchCoordinator: ObservableObject {
    @Published private(set) var videos: [ConsoleLocalVideo] = []
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentVideo: ConsoleLocalVideo?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hudVisible = true
    @Published private(set) var webURL: URL?
    @Published private(set) var webEscapeVisible = false
    @Published private(set) var webEscapeFocus = 0
    @Published private(set) var hiddenAppIDs: Set<String>
    @Published private(set) var customApps: [ConsoleMediaApp]
    @Published var customTargetText = ""
    var webKeyForwarder: ((String) -> Void)?

    private let defaults: UserDefaults
    private var progressByPath: [String: TimeInterval]
    private var timeObserver: Any?
    private var hudTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private let progressURL: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenAppIDs = Set(defaults.stringArray(forKey: "launcher.media.hiddenApps") ?? [])
        customApps = Self.loadCustomApps(defaults: defaults)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalOS/Media", isDirectory: true)
        progressURL = support.appendingPathComponent("playback-progress.json")
        progressByPath = (try? Data(contentsOf: progressURL)).flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: $0) } ?? [:]
    }

    var apps: [ConsoleMediaApp] {
        ConsoleMediaApp.curated.filter { $0.id != "all" && !hiddenAppIDs.contains($0.id) } + customApps + [ConsoleMediaApp.curated[7]]
    }

    var isLocalVideoPlayerPresented: Bool { player != nil && currentVideo != nil }
    func savedProgress(for id: String) -> TimeInterval { progressByPath[id] ?? 0 }

    func scan(folders: [String]) {
        thumbnailTask?.cancel()
        let folders = folders.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies").path]
            : folders
        thumbnailTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.findVideos(in: folders) }.value
            guard let self, !Task.isCancelled else { return }
            self.videos = found
            await self.loadThumbnails(for: found)
        }
    }

    func launch(_ app: ConsoleMediaApp, focus: FocusCoordinator) {
        switch app.target {
        case .localLibrary:
            focus.focus(.mediaBelowFold(row: 0, index: 0))
        case .web(let url):
            openWeb(url, focus: focus)
        case .native(let bundleID, let fallback):
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                openExternalApplication(at: appURL, title: app.name)
            } else {
                openExternalURL(fallback, title: app.name)
            }
        case .appBundle(let appURL):
            openExternalApplication(at: appURL, title: app.name)
        case .appManager:
            focus.presentMediaModal(.appManager)
        }
    }

    private func openExternalApplication(at url: URL, title: String) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { application, error in
            guard error == nil, let application else { return }
            Task { @MainActor in
                ConsoleShellCoordinator.shared.yieldToExternalApp(pid: application.processIdentifier,
                    bundleID: application.bundleIdentifier, gameID: nil, title: title, application: application)
            }
        }
    }

    private func openExternalURL(_ url: URL, title: String) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { application, error in
            guard error == nil else { return }
            Task { @MainActor in
                let resolved = application ?? NSWorkspace.shared.frontmostApplication
                ConsoleShellCoordinator.shared.yieldToExternalApp(pid: resolved?.processIdentifier,
                    bundleID: resolved?.bundleIdentifier, gameID: nil, title: title, application: resolved)
            }
        }
    }

    func openWeb(_ url: URL, focus: FocusCoordinator) {
        webURL = url
        webEscapeVisible = false
        webEscapeFocus = 0
        focus.presentMediaModal(.consoleWebPlayer)
        UISoundManager.suspendForGameLaunch()
    }

    func play(_ video: ConsoleLocalVideo, focus: FocusCoordinator) {
        stopPlayer(saveProgress: false)
        currentVideo = video
        let nextPlayer = AVPlayer(url: video.url)
        player = nextPlayer
        duration = video.duration
        currentTime = min(progressByPath[video.id] ?? 0, max(0, video.duration - 2))
        nextPlayer.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        installTimeObserver(on: nextPlayer)
        nextPlayer.play()
        isPlaying = true
        showHUD()
        focus.presentMediaModal(.localVideoPlayer)
        UISoundManager.suspendForGameLaunch()
    }

    func handleModalAction(_ action: ConsoleInputAction, focus: FocusCoordinator, input: ConsoleInputManager) {
        switch focus.activeMediaModal {
        case .localVideoPlayer:
            handlePlayerAction(action, focus: focus)
        case .consoleWebPlayer:
            handleWebAction(action, focus: focus)
        case .appManager:
            handleManagerAction(action, focus: focus, input: input)
        case nil: break
        }
    }

    func stopPlayer(saveProgress: Bool = true) {
        guard let player else { return }
        if saveProgress, let currentVideo {
            let seconds = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime)
            progressByPath[currentVideo.id] = seconds
            persistProgress()
        }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause()
        self.player = nil
        currentVideo = nil
        isPlaying = false
        UISoundManager.resumeFromGame()
    }

    func toggleApp(_ id: String) {
        if hiddenAppIDs.contains(id) { hiddenAppIDs.remove(id) } else { hiddenAppIDs.insert(id) }
        defaults.set(Array(hiddenAppIDs), forKey: "launcher.media.hiddenApps")
    }

    func addCustomTarget() {
        let raw = customTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let target: ConsoleMediaApp.LaunchTarget
        if raw.hasSuffix(".app"), FileManager.default.fileExists(atPath: raw) {
            target = .appBundle(URL(fileURLWithPath: raw))
        } else if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil {
            target = .web(url)
        } else { return }
        let name = targetTitle(raw)
        let app = ConsoleMediaApp(id: "custom-\(UUID().uuidString)", name: name, subtitle: raw, symbol: "play.rectangle.on.rectangle.fill",
                                  colors: [Color(red: 0.35, green: 0.43, blue: 0.58), Color(red: 0.11, green: 0.14, blue: 0.23)], target: target, isCustom: true)
        customApps.append(app)
        persistCustomApps()
        customTargetText = ""
    }

    func removeMediaCustomTarget(at index: Int) { removeCustomApp(at: index) }

    func configureManagerFocus(_ index: Int) { managerFocus = max(0, index) }

    func showWebEscapeBar() {
        webEscapeVisible = true
        webEscapeFocus = min(max(0, webEscapeFocus), 1)
    }

    func resumeWeb() { webEscapeVisible = false }

    func returnFromWeb(focus: FocusCoordinator) {
        webURL = nil
        webEscapeVisible = false
        webKeyForwarder = nil
        focus.dismissMediaModal()
        UISoundManager.resumeFromGame()
    }

    private func handlePlayerAction(_ action: ConsoleInputAction, focus: FocusCoordinator) {
        switch action {
        case .confirm:
            guard let player else { return }
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            showHUD()
        case .move(.left): seek(by: -10)
        case .move(.right): seek(by: 10)
        case .move(.up), .move(.down): showHUD()
        case .tabLeft: seek(by: -30)
        case .tabRight: seek(by: 30)
        case .back:
            stopPlayer()
            focus.dismissMediaModal()
            focus.focus(.mediaHeroActions(.open))
        case .home:
            stopPlayer()
            focus.dismissMediaModal()
            focus.focus(.mediaRibbon(focus.selectedMediaIndex))
        case .options: showHUD()
        case .search: break
        }
    }

    private func handleWebAction(_ action: ConsoleInputAction, focus: FocusCoordinator) {
        switch action {
        case .back, .home:
            if webEscapeVisible { returnFromWeb(focus: focus) }
            else { showWebEscapeBar() }
        case .move(.left):
            if webEscapeVisible { webEscapeFocus = max(0, webEscapeFocus - 1) } else { webKeyForwarder?("ArrowLeft") }
        case .move(.right):
            if webEscapeVisible { webEscapeFocus = min(1, webEscapeFocus + 1) } else { webKeyForwarder?("ArrowRight") }
        case .move(.up):
            if webEscapeVisible { webEscapeFocus = 0 } else { webKeyForwarder?("ArrowUp") }
        case .move(.down):
            if webEscapeVisible { webEscapeFocus = 1 } else { webKeyForwarder?("ArrowDown") }
        case .confirm:
            if !webEscapeVisible { webKeyForwarder?("Enter") }
            else if webEscapeFocus == 0 { resumeWeb() }
            else { returnFromWeb(focus: focus) }
        case .tabLeft, .tabRight, .options, .search:
            showWebEscapeBar()
        }
    }

    private func handleManagerAction(_ action: ConsoleInputAction, focus: FocusCoordinator, input: ConsoleInputManager) {
        let customCount = customApps.count
        let curated = ConsoleMediaApp.curated.filter { $0.id != "all" }
        let last = curated.count + customCount + 1
        switch action {
        case .back, .home:
            input.textEntryActive = false
            focus.dismissMediaModal()
        case .move(.up):
            managerFocus = max(0, managerFocus - 1)
        case .move(.down):
            managerFocus = min(last, managerFocus + 1)
        case .move(.left), .move(.right), .tabLeft, .tabRight, .options, .search: break
        case .confirm:
            if managerFocus < curated.count { toggleApp(curated[managerFocus].id) }
            else if managerFocus < curated.count + customCount { removeCustomApp(at: managerFocus - curated.count) }
            else if managerFocus == curated.count + customCount {
                if input.textEntryActive {
                    addCustomTarget()
                    input.textEntryActive = false
                } else { input.textEntryActive = true }
            }
            else { addCustomTarget() }
        }
    }

    @Published private(set) var managerFocus = 0

    private func removeCustomApp(at index: Int) {
        guard customApps.indices.contains(index) else { return }
        customApps.remove(at: index)
        persistCustomApps()
    }

    private func seek(by seconds: TimeInterval) {
        guard let player else { return }
        let upper = duration > 0 ? duration : currentTime + seconds
        let target = min(max(0, currentTime + seconds), max(0, upper))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        showHUD()
    }

    private func showHUD() {
        hudVisible = true
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hudVisible = false
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite { self.duration = max(0, itemDuration) }
            }
        }
    }

    private func loadThumbnails(for videos: [ConsoleLocalVideo]) async {
        let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalOS/Media/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for start in stride(from: 0, to: videos.count, by: 3) {
            let batch = Array(videos[start..<min(start + 3, videos.count)])
            let results = await withTaskGroup(of: (String, String?, TimeInterval).self, returning: [(String, String?, TimeInterval)].self) { group in
                for video in batch {
                    group.addTask {
                        await Task.detached(priority: .utility) { await Self.makeThumbnail(for: video.url, in: cacheDirectory) }.value
                    }
                }
                var values: [(String, String?, TimeInterval)] = []
                for await result in group { values.append(result) }
                return values
            }
            for (path, thumbnail, duration) in results {
                guard let index = videos.firstIndex(where: { $0.id == path }) else { continue }
                self.videos[index].thumbnailPath = thumbnail
                self.videos[index].duration = duration
            }
        }
    }

    private func persistProgress() {
        let url = progressURL
        let snapshot = progressByPath
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func persistCustomApps() {
        let values = customApps.map { ["id": $0.id, "name": $0.name, "target": $0.subtitle, "isApp": $0.subtitle.hasSuffix(".app")] }
        defaults.set(values, forKey: "launcher.media.customApps")
    }

    private static func loadCustomApps(defaults: UserDefaults) -> [ConsoleMediaApp] {
        (defaults.array(forKey: "launcher.media.customApps") as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String, let raw = item["target"] as? String else { return nil }
            let target: ConsoleMediaApp.LaunchTarget
            if (item["isApp"] as? Bool == true), FileManager.default.fileExists(atPath: raw) { target = .appBundle(URL(fileURLWithPath: raw)) }
            else if let url = URL(string: raw) { target = .web(url) }
            else { return nil }
            return ConsoleMediaApp(id: id, name: name, subtitle: raw, symbol: "play.rectangle.on.rectangle.fill",
                                   colors: [Color(red: 0.35, green: 0.43, blue: 0.58), Color(red: 0.11, green: 0.14, blue: 0.23)], target: target, isCustom: true)
        }
    }

    private func targetTitle(_ raw: String) -> String {
        URL(string: raw)?.host?.replacingOccurrences(of: "www.", with: "").capitalized
            ?? URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
    }

    nonisolated private static func findVideos(in folders: [String]) -> [ConsoleLocalVideo] {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpg", "mpeg"]
        var found: [ConsoleLocalVideo] = []
        let manager = FileManager.default
        for folder in folders {
            let root = URL(fileURLWithPath: folder, isDirectory: true)
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(ConsoleLocalVideo(url: url, thumbnailPath: nil, duration: 0))
                if found.count >= 500 { return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func makeThumbnail(for url: URL, in cacheDirectory: URL) async -> (String, String?, TimeInterval) {
        let key = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = cacheDirectory.appendingPathComponent("\(key).jpg").path
        let asset = AVURLAsset(url: url)
        let assetDuration = (try? await asset.load(.duration))?.seconds ?? 0
        let duration = assetDuration.isFinite ? assetDuration : 0
        if FileManager.default.fileExists(atPath: path) { return (url.path, path, duration) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 450)
        let thumbnailTime = duration.isFinite ? min(30, max(0, duration * 0.24)) : 0
        let time = CMTime(seconds: thumbnailTime, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return (url.path, nil, duration) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else { return (url.path, nil, duration) }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return (url.path, path, duration)
    }
}

struct ConsoleMediaPlayerOverlay: View {
    @ObservedObject var media: MediaLaunchCoordinator

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let player = media.player {
                ConsoleAVPlayerSurface(player: player).ignoresSafeArea()
            }
            if media.hudVisible {
                VStack(spacing: 12) {
                    HStack {
                        Text(media.currentVideo?.title ?? "Now Playing").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text(media.isPlaying ? "Playing" : "Paused").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.66))
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(.white).frame(width: proxy.size.width * (media.duration > 0 ? min(1, media.currentTime / media.duration) : 0))
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(media.currentTime.mediaClock)
                        Spacer()
                        Text("−\(max(0, media.duration - media.currentTime).mediaClock)")
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    Text("A  Play / Pause     ◀  −10 sec     ▶  +10 sec     L1 / R1  ±30 sec     Esc  Back")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                .padding(23)
                .frame(maxWidth: 850)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { NSCursor.hide() }
        .onDisappear { NSCursor.unhide() }
        .animation(.easeOut(duration: 0.22), value: media.hudVisible)
    }
}

struct ConsoleMediaWebOverlay: View {
    @ObservedObject var media: MediaLaunchCoordinator
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if let url = media.webURL {
                ConsoleMediaWebSurface(url: url) { media.webKeyForwarder = $0 }
                    .ignoresSafeArea()
            }
            if media.webEscapeVisible {
                Color.black.opacity(0.4).ignoresSafeArea()
                HStack(spacing: 14) {
                    Button { media.resumeWeb() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(ConsoleMediaOverlayButtonStyle(focused: media.webEscapeFocus == 0))
                    Button(action: onDismiss) { Label("Return to Media Hub", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ConsoleMediaOverlayButtonStyle(focused: media.webEscapeFocus == 1))
                }
                .padding(22)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { NSCursor.hide() }
        .onDisappear { NSCursor.unhide() }
        .animation(.easeOut(duration: 0.2), value: media.webEscapeVisible)
    }
}

struct ConsoleMediaAppManagerOverlay: View {
    @ObservedObject var media: MediaLaunchCoordinator
    let onEditingChanged: (Bool) -> Void
    @FocusState private var targetFieldFocused: Bool

    private var curated: [ConsoleMediaApp] { ConsoleMediaApp.curated.filter { $0.id != "all" } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("Media Apps").font(.system(size: 34, weight: .medium, design: .rounded))
                Text("Choose what appears in your media ribbon, or add a web destination or installed app bundle.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.68))
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(curated.enumerated()), id: \.element.id) { index, app in
                            appToggle(app, index: index)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(media.customApps.enumerated()), id: \.element.id) { index, app in
                            customAppRow(app, index: curated.count + index)
                        }
                        TextField("https://… or /Applications/App.app", text: $media.customTargetText, onEditingChanged: onEditingChanged)
                            .textFieldStyle(.plain).padding(14).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .focused($targetFieldFocused)
                            .onSubmit { media.addCustomTarget(); onEditingChanged(false) }
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targetFieldFocused ? .white.opacity(0.9) : .white.opacity(0.12), lineWidth: targetFieldFocused ? 2 : 1))
                        Button { media.addCustomTarget(); onEditingChanged(false) } label: {
                            Label("Add to Media", systemImage: "plus")
                                .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 17).frame(height: 44)
                                .background(.white.opacity(media.managerFocus == curated.count + media.customApps.count + 1 ? 0.18 : 0.07), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(media.managerFocus == curated.count + media.customApps.count + 1 ? 0.9 : 0.14), lineWidth: media.managerFocus == curated.count + media.customApps.count + 1 ? 2 : 1))
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                }
                Text("Esc  Close").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(52)
            .frame(maxWidth: 1150, maxHeight: .infinity, alignment: .leading)
        }
        .onAppear { NSCursor.hide() }
        .onDisappear { NSCursor.unhide() }
        .onChange(of: media.managerFocus) { _, focus in
            targetFieldFocused = focus == curated.count + media.customApps.count
            if targetFieldFocused { onEditingChanged(true) } else { onEditingChanged(false) }
        }
    }

    private func appToggle(_ app: ConsoleMediaApp, index: Int) -> some View {
        let focused = media.managerFocus == index
        let enabled = !media.hiddenAppIDs.contains(app.id)
        return HStack(spacing: 14) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(enabled ? .white : .white.opacity(0.44))
            Image(systemName: app.symbol).frame(width: 24)
            Text(app.name).font(.system(size: 16, weight: .medium))
            Spacer()
            Text(enabled ? "Shown" : "Hidden").font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 16).frame(width: 420, height: 55)
        .background(focused ? .white.opacity(0.1) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(focused ? 0.9 : 0.11), lineWidth: focused ? 2 : 1))
        .accessibilityElement(children: .combine)
    }

    private func customAppRow(_ app: ConsoleMediaApp, index: Int) -> some View {
        let focused = media.managerFocus == index
        return HStack(spacing: 12) {
            Image(systemName: app.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(app.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer()
            Image(systemName: "minus.circle")
        }
        .padding(12).background(focused ? .white.opacity(0.1) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(focused ? 0.9 : 0.11), lineWidth: focused ? 2 : 1))
    }
}

private struct ConsoleAVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerLayerView {
        let view = AVPlayerLayerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerLayerView, context: Context) { view.playerLayer.player = player }
}

private final class AVPlayerLayerView: NSView {
    override var wantsUpdateLayer: Bool { true }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override func makeBackingLayer() -> CALayer { let layer = AVPlayerLayer(); layer.videoGravity = .resizeAspect; return layer }
}

private struct ConsoleMediaWebSurface: NSViewRepresentable {
    let url: URL
    let onReady: (@escaping (String) -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .black
        view.allowsBackForwardNavigationGestures = false
        view.enclosingScrollView?.hasVerticalScroller = false
        view.enclosingScrollView?.hasHorizontalScroller = false
        context.coordinator.webView = view
        onReady { [weak coordinator = context.coordinator] key in coordinator?.forward(key) }
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    final class Coordinator {
        weak var webView: WKWebView?
        func forward(_ key: String) {
            guard let data = try? JSONSerialization.data(withJSONObject: [key]), let encoded = String(data: data, encoding: .utf8),
                  let quotedKey = encoded.dropFirst().dropLast().split(separator: ",").first else { return }
            webView?.evaluateJavaScript("window.dispatchEvent(new KeyboardEvent('keydown',{key:\(quotedKey),bubbles:true}));")
        }
    }
}

private struct ConsoleMediaOverlayButtonStyle: ButtonStyle {
    let focused: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .foregroundStyle(focused ? Color.black : Color.white)
            .padding(.horizontal, 22).frame(height: 54)
            .background(focused ? Color.white : Color.white.opacity(0.13), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.04 : 1)
    }
}

extension TimeInterval {
    var mediaClock: String {
        guard isFinite else { return "0:00" }
        let seconds = max(0, Int(self))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
