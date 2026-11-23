import SwiftUI

struct ConsoleLauncherView: View {
    private struct SampleGame: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let artwork: String
        let wallpaper: WallpaperPreset
        let lastPlayed: String
        let playtime: String
        let progress: Double
        var isAvailable = true
        var tilePaths: [String] = []
        var heroPaths: [String] = []
        var summary: String? = nil
        var localLogoPath: String? = nil
        var storyline: String? = nil
        var releaseYear: Int? = nil
        var developers: [String] = []
        var publishers: [String] = []
        var genres: [String] = []
        var platforms: [String] = []
        var installLocation: String? = nil
        var videos: [GameDBVideo] = []
        var screenshotPaths: [String] = []
        var playedSeconds: TimeInterval = 0
        var lastPlayedDate: Date? = nil
    }

    @State private var selectedID = "horizon"
    @State private var showingOptions = false
    @State private var artworkGameID = "horizon"
    @State private var fadingArtworkPaths: [String]?
    @State private var ambientDrift = false
    @State private var bootChimePlayed = false
    @State private var boundaryNudge: CGFloat = 0
    @State private var libraryHeroOverride: ConsoleLibraryGame?
    @State private var globalSearchQuery = ""
    @State private var recentSearches = UserDefaults.standard.stringArray(forKey: "console.search.recent.player-1") ?? []
    @State private var librarySnapshotInitialized = false
    @StateObject private var focusCoordinator = FocusCoordinator(gameCount: 5)
    @StateObject private var inputManager = ConsoleInputManager()
    @StateObject private var networkStatus = NetworkPathStatus()
    @StateObject private var libraryModel = ConsoleGameLibraryModel()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var playtimeTracker = PlaytimeTracker(profileID: "player-1")
    @StateObject private var mediaCoordinator = MediaLaunchCoordinator()
    @StateObject private var gameLaunchCoordinator = GameLaunchCoordinator.shared
    @ObservedObject private var shellCoordinator = ConsoleShellCoordinator.shared
    @ObservedObject private var launcherSettings = ConsoleSettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusTarget: ConsoleFocusTarget { focusCoordinator.focusTarget }
    private var isShowingOverview: Bool { focusCoordinator.showingBelowFold }

    private static let emptyLibrarySelection = SampleGame(id: "__empty-library__", title: "No Games Found", subtitle: "SCAN YOUR LIBRARY TO GET STARTED", artwork: "gamecontroller", wallpaper: .metalOSHorizon, lastPlayed: "Not played", playtime: "—", progress: 0)

    private var games: [SampleGame] {
        let local = libraryStore.consoleGames
        return local.map { game in
            let tiles = [game.tileArt?.path, game.boxArt?.path, game.artworkPath].compactMap { $0 }
            let heroes = [game.heroArt?.path].compactMap { $0 } + tiles + (game.metadata?.screenshots.map(\.path) ?? [])
            let minutes = Int((game.playedSeconds ?? 0) / 60)
            return SampleGame(id: game.id, title: game.displayTitle,
                subtitle: game.metadata?.developers.first?.uppercased() ?? game.source.rawValue.uppercased(),
                artwork: game.source.symbol, wallpaper: .metalOSHorizon,
                lastPlayed: game.lastPlayed?.formatted(date: .abbreviated, time: .omitted) ?? "Not played",
                playtime: minutes == 0 ? "—" : "\(minutes / 60)h \(minutes % 60)m",
                progress: game.metadata == nil ? 0 : 1, isAvailable: game.isAvailable,
                tilePaths: tiles, heroPaths: heroes,
                summary: game.metadata?.summary, localLogoPath: game.metadata?.localLogoPath,
                storyline: game.metadata?.storyline, releaseYear: game.metadata?.releaseYear,
                developers: game.metadata?.developers ?? [], publishers: game.metadata?.publishers ?? [],
                genres: game.metadata?.genres ?? [], platforms: game.metadata?.platforms ?? [],
                installLocation: URL(fileURLWithPath: game.installPath).deletingLastPathComponent().lastPathComponent,
                videos: game.metadata?.videos ?? [], screenshotPaths: game.metadata?.screenshots.map(\.path) ?? [],
                playedSeconds: game.playedSeconds ?? 0, lastPlayedDate: game.lastPlayed)
        }
    }

    private enum OverviewMediaItem: Identifiable {
        case trailer(GameDBVideo)
        case screenshot(String)
        var id: String {
            switch self { case .trailer(let video): "trailer-\(video.id)"; case .screenshot(let path): "screenshot-\(path)" }
        }
    }

    private struct OverviewCard: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let symbol: String
        let badge: String
    }

    private var selectedGame: SampleGame { games.first(where: { $0.id == selectedID }) ?? Self.emptyLibrarySelection }
    private var mediaApps: [ConsoleMediaApp] { mediaCoordinator.apps }
    private var selectedMediaApp: ConsoleMediaApp {
        guard mediaApps.indices.contains(focusCoordinator.selectedMediaIndex) else { return ConsoleMediaApp.curated[0] }
        return mediaApps[focusCoordinator.selectedMediaIndex]
    }
    private var continueWatchingVideos: [ConsoleLocalVideo] {
        mediaCoordinator.videos.filter { video in
            let played = mediaCoordinator.savedProgress(for: video.id)
            return played > 20 && played < max(0, video.duration - 45)
        }
    }
    private var mediaRowCounts: [Int] {
        switch selectedMediaApp.id {
        case "local": [max(1, continueWatchingVideos.count), max(1, mediaCoordinator.videos.count)]
        case "youtube": [4, 4]
        case "all": [1]
        default: [1]
        }
    }
    private var activeArtworkPaths: [String] {
        guard let game = games.first(where: { $0.id == artworkGameID }) else { return [] }
        return game.heroPaths + (game.wallpaper.imageURL.map { [$0.path] } ?? [])
    }
    private func artworkPaths(for gameID: String) -> [String]? {
        guard let game = games.first(where: { candidate in candidate.id == gameID }) else { return nil }
        var paths = game.heroPaths
        if let wallpaper = game.wallpaper.imageURL { paths.append(wallpaper.path) }
        return paths
    }
    private var overviewMediaItems: [OverviewMediaItem] {
        let videos = selectedGame.videos.map(OverviewMediaItem.trailer)
        let screenshots = selectedGame.screenshotPaths.map(OverviewMediaItem.screenshot)
        return videos + screenshots
    }
    private var activePlaytime: PlaytimeRecord {
        playtimeTracker.stats(for: selectedGame.id, fallbackSeconds: selectedGame.playedSeconds, fallbackLastPlayed: selectedGame.lastPlayedDate)
    }
    private var globalSearchResults: [ConsoleGlobalSearchResult] {
        let query = globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let filter = ConsoleGlobalSearchFilter(rawValue: focusCoordinator.globalSearchFilterIndex) ?? .all
        var items: [ConsoleGlobalSearchResult] = []
        if filter == .all || filter == .games {
            items += games.filter { game in
                let metadata = libraryStore.consoleGames.first(where: { $0.id == game.id })?.metadata
                let text = ([game.title, game.subtitle] + game.developers + game.genres + (metadata?.platforms ?? [])).joined(separator: " ")
                return text.localizedCaseInsensitiveContains(query)
            }.map { game in
                ConsoleGlobalSearchResult(id: game.id, kind: .game, title: game.title,
                    subtitle: game.platforms.first ?? game.subtitle, symbol: game.artwork, artworkPath: game.tilePaths.first)
            }
        }
        if filter == .all || filter == .media {
            items += mediaCoordinator.videos.filter { $0.title.localizedCaseInsensitiveContains(query) }.map { video in
                ConsoleGlobalSearchResult(id: video.id, kind: .video, title: video.title, subtitle: "Local video", symbol: "play.rectangle.fill", artworkPath: video.thumbnailPath)
            }
            items += mediaApps.filter { "\($0.name) \($0.subtitle)".localizedCaseInsensitiveContains(query) }.map { app in
                ConsoleGlobalSearchResult(id: app.id, kind: .mediaApp, title: app.name, subtitle: app.subtitle, symbol: app.symbol)
            }
        }
        if filter == .all || filter == .settings {
            let settings: [(String, String, String, ConsoleSettingsCategory, String)] = [
                ("battery", "Controller Battery", "Battery level and controller connection", .controllers, "battery.25percent"),
                ("theme", "Theme & Focus", "Focus lighting, glass and system clock", .theme, "circle.lefthalf.filled"),
                ("paths", "Game Paths", "Folders scanned for installed games", .gamePaths, "folder.fill"),
                ("audio", "Audio", "Sound effects, ambient music and volume", .audio, "speaker.wave.2.fill"),
                ("display", "Display & Safe Area", "Screen target, safe area and motion", .display, "display"),
                ("controller-prompts", "Controller Prompts", "Button glyphs and navigation feel", .controllers, "gamecontroller.fill")
            ]
            items += settings.filter { "\($0.0) \($0.1) \($0.2)".localizedCaseInsensitiveContains(query) }.map { item in
                ConsoleGlobalSearchResult(id: "setting:\(item.3.rawValue):\(item.0)", kind: .setting, title: item.1, subtitle: item.2, symbol: item.4)
            }
        }
        return Array(items.prefix(32))
    }

    var body: some View {
        GeometryReader { proxy in
            attachLifecycle(to: consoleScene(size: proxy.size))
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .background(.black)
    }

    private func consoleScene(size: CGSize) -> some View {
        let horizontalInset = max(48, size.width * 0.052)
        let verticalInset = max(28, size.height * 0.043)
        return ZStack {
            backdrop
            primaryScreen(size: size, horizontalInset: horizontalInset, verticalInset: verticalInset)
            overlayLayers
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
    }

    @ViewBuilder private func primaryScreen(size: CGSize, horizontalInset: CGFloat, verticalInset: CGFloat) -> some View {
        if focusCoordinator.isSettingsPresented {
            ConsoleSystemSettingsView(focus: focusCoordinator, input: inputManager,
                onSound: { UISoundManager.soundEffectsVolume = Float(launcherSettings.uiSoundVolume) },
                onDisplaySelected: { (NSApp.delegate as? StudioAppDelegate)?.moveConsole(toDisplay: $0) })
                .transition(.move(edge: .trailing).combined(with: .opacity)).zIndex(2)
        } else if focusCoordinator.isLibraryPresented {
            ConsoleGameLibraryView(focus: focusCoordinator, model: libraryModel,
                onPlay: launchLibraryGame, onDetails: showLibraryGameInHero,
                onHide: { libraryStore.setHidden(true, gameID: $0) },
                onRemoveCustom: { id in if id.hasPrefix("manual:") { libraryStore.removeGame(id: id) } })
                .transition(.scale(scale: 0.975).combined(with: .opacity)).zIndex(1)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer().frame(height: size.height * 0.095)
                if focusCoordinator.selectedTab == .games && !isShowingOverview {
                    gameRibbon(tileSide: ribbonTileSide(size), availableWidth: size.width - horizontalInset * 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer(minLength: 24)
                    heroZone(compact: size.height < 740).transition(.move(edge: .leading).combined(with: .opacity))
                } else if focusCoordinator.selectedTab == .media && !focusCoordinator.showingMediaBelowFold {
                    mediaRibbon(tileSide: ribbonTileSide(size), availableWidth: size.width - horizontalInset * 2)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer(minLength: 24)
                    mediaHero(compact: size.height < 740).transition(.move(edge: .trailing).combined(with: .opacity))
                } else if isShowingOverview {
                    overview(size: size).transition(.move(edge: .bottom).combined(with: .opacity))
                } else if focusCoordinator.showingMediaBelowFold {
                    mediaOverview(size: size).transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    mediaLanding
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, horizontalInset).padding(.top, verticalInset).padding(.bottom, verticalInset)
            .transition(.scale(scale: 1.015).combined(with: .opacity))
        }
    }

    @ViewBuilder private var overlayLayers: some View {
        if showingOptions { optionsScrim.transition(.opacity).zIndex(2) }
        if focusCoordinator.isControlCenterPresented {
            ConsoleControlCenterView(focus: focusCoordinator, network: networkStatus.snapshot,
                                     controllers: inputManager.connectedControllers,
                                     activeAppTitle: shellCoordinator.activeExternalAppTitle,
                                     onPowerAction: handlePowerAction)
                .transition(.opacity).zIndex(3)
        }
        if let modal = focusCoordinator.activeOverviewModal {
            ConsoleOverviewOverlay(modal: modal) { focusCoordinator.handle(.back) }.transition(.opacity).zIndex(5)
        }
        if let modal = focusCoordinator.activeMediaModal {
            mediaModalView(modal).transition(.opacity).zIndex(6)
        }
        if focusCoordinator.isGlobalSearchPresented {
            ConsoleGlobalSearchView(focus: focusCoordinator, query: $globalSearchQuery,
                recentSearches: recentSearches, results: globalSearchResults,
                onResult: selectGlobalSearchResult, onKey: handleGlobalSearchKey, onRecent: useRecentSearch)
                .transition(.opacity.combined(with: .scale(scale: 0.985))).zIndex(20)
        }
        ConsoleToastLayer().zIndex(30)
        if shellCoordinator.isTransitioningToExternalApp {
            Color.black.ignoresSafeArea().transition(.opacity).zIndex(40)
        }
        if let gameID = gameLaunchCoordinator.splashGameID,
           let game = libraryStore.data.games.first(where: { $0.id == gameID }) {
            ConsoleLaunchSplash(game: game).transition(.opacity).zIndex(50)
        }
    }

    @ViewBuilder private func mediaModalView(_ modal: ConsoleMediaModal) -> some View {
        switch modal {
        case .localVideoPlayer: ConsoleMediaPlayerOverlay(media: mediaCoordinator)
        case .consoleWebPlayer:
            ConsoleMediaWebOverlay(media: mediaCoordinator) { mediaCoordinator.returnFromWeb(focus: focusCoordinator) }
        case .appManager:
            ConsoleMediaAppManagerOverlay(media: mediaCoordinator) { inputManager.textEntryActive = $0 }
        }
    }

    private func ribbonTileSide(_ size: CGSize) -> CGFloat { min(174, max(132, size.height * 0.19)) }

    private func attachLifecycle<V: View>(to view: V) -> some View {
        let core = attachCoreLifecycle(to: view)
        let content = attachContentLifecycle(to: core)
        return attachPreferenceLifecycle(to: content)
    }

    private func attachCoreLifecycle<V: View>(to view: V) -> some View {
        view.onAppear {
            // Defer startup mutations until SwiftUI has finished its initial graph update.
            DispatchQueue.main.async { prepareLauncher() }
        }
            .task(id: selectedID) { await crossfadeGameArtwork(to: selectedID) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification), perform: handleApplicationActivation)
            .onChange(of: artworkGameID) { oldID, newID in gameArtworkChanged(from: oldID, to: newID) }
            .onDisappear(perform: cleanUpLauncher)
    }

    private func attachContentLifecycle<V: View>(to view: V) -> some View {
        let media = attachMediaLifecycle(to: view)
        let library = attachLibraryLifecycle(to: media)
        return attachSystemLifecycle(to: library)
    }

    private func attachMediaLifecycle<V: View>(to view: V) -> some View {
        view.onChange(of: selectedID) { _, id in selectedGameChanged(id) }
            .onChange(of: focusCoordinator.selectedMediaIndex) { _, index in selectedMediaChanged(index) }
            .onChange(of: mediaApps.map(\.id)) { _, ids in mediaAppsChanged(ids.count) }
            .onChange(of: launcherSettings.mediaFolders) { _, folders in mediaCoordinator.scan(folders: folders.filter(\.enabled).map(\.path)) }
            .onChange(of: mediaCoordinator.videos) { _, _ in focusCoordinator.synchronizeMediaBelowFoldRows(cardCounts: mediaRowCounts) }
    }

    private func attachLibraryLifecycle<V: View>(to view: V) -> some View {
        view
            .onChange(of: libraryStore.data.games.map(\.id)) { oldIDs, newIDs in
                libraryGamesChanged()
                guard librarySnapshotInitialized else { librarySnapshotInitialized = true; return }
                let added = newIDs.filter { !oldIDs.contains($0) }.count
                ConsoleToastManager.shared.notifyNewGames(added)
            }
            .onChange(of: libraryStore.data.games.compactMap(\.heroArt?.path)) { _, _ in libraryModel.synchronize(with: libraryStore.consoleGames) }
            .onChange(of: libraryStore.data.games.compactMap { $0.metadata?.sourceURL }) { old, new in
                if !old.isEmpty && old != new { ConsoleToastManager.shared.notifyMetadataRefresh() }
            }
            .onChange(of: libraryModel.favoriteIDs) { oldIDs, newIDs in
                let changed = oldIDs.symmetricDifference(newIDs)
                if changed.count == 1, let id = changed.first { ConsoleToastManager.shared.notifyFavoriteAdded(newIDs.contains(id)) }
            }
            .onChange(of: libraryStore.data.games.map { $0.metadata?.videoIDs ?? [] }) { _, _ in focusCoordinator.synchronizeBelowFoldRows(cardCounts: [3, max(1, overviewMediaItems.count), 1]) }
    }

    private func attachSystemLifecycle<V: View>(to view: V) -> some View {
        view
            .onChange(of: networkStatus.snapshot.connected) { _, connected in ConsoleToastManager.shared.networkChanged(connected: connected) }
            .onChange(of: libraryHeroOverride?.id) { _, id in if let id { UISoundManager.onGameFocusChanged(id) } }
            .onChange(of: inputManager.connectedControllers.count) { _, count in focusCoordinator.synchronizeControllerCount(count) }
    }

    private func attachPreferenceLifecycle<V: View>(to view: V) -> some View {
        view
            .onChange(of: launcherSettings.reducedMotion) { _, reduced in updateAmbientMotion(reduced: reduced) }
            .onChange(of: launcherSettings.livingBackground) { _, enabled in updateAmbientMotion(enabled: enabled) }
            .onChange(of: launcherSettings.stickDeadzone) { _, value in inputManager.stickDeadzone = Float(value) }
            .onChange(of: launcherSettings.repeatSpeed) { _, speed in applyRepeatSpeed(speed) }
            .onChange(of: showingOptions) { _, isOpen in optionsVisibilityChanged(isOpen) }
            .animation(ConsoleMotion.zoneSpring, value: isShowingOverview)
            .animation(ConsoleMotion.zoneSpring, value: focusCoordinator.selectedTab)
            .animation(ConsoleMotion.zoneSpring, value: focusCoordinator.isControlCenterPresented)
            .animation(ConsoleMotion.zoneSpring, value: focusCoordinator.isLibraryPresented)
            .animation(ConsoleMotion.zoneSpring, value: focusCoordinator.showingMediaBelowFold)
            .animation(launcherSettings.reducedMotion ? .easeOut(duration: 0.12) : ConsoleMotion.zoneSpring, value: focusCoordinator.isSettingsPresented)
            .animation(ConsoleMotion.zoneSpring, value: shellCoordinator.isTransitioningToExternalApp)
    }

    private func prepareLauncher() {
        configureConsoleNavigation()
        inputManager.start()
        shellCoordinator.register(input: inputManager, focus: focusCoordinator, playtime: playtimeTracker)
        libraryStore.onConsoleExternalApplicationLaunched = { application, gameID, title in
            gameLaunchCoordinator.handoffStarted(gameID: gameID)
            shellCoordinator.yieldToExternalApp(pid: application.processIdentifier, bundleID: application.bundleIdentifier,
                gameID: gameID, title: title, application: application)
        }
        libraryStore.onConsoleManagedProcessLaunched = { pid, gameID, title in
            gameLaunchCoordinator.handoffStarted(gameID: gameID)
            shellCoordinator.yieldToExternalApp(pid: pid, bundleID: nil, gameID: gameID, title: title)
        }
        launcherSettings.scanLibraryAction = { await libraryStore.scan() }
        libraryModel.onFavoriteChanged = { id, value in libraryStore.setFavorite(value, gameID: id) }
        libraryModel.onCollectionChanged = { id, collectionID in libraryStore.setCollection(collectionID, containsGame: id) }
        ConsoleToastManager.shared.start()
        applyNavigationPreferences()
        focusCoordinator.synchronizeControllerCount(inputManager.connectedControllers.count)
        if launcherSettings.autoScan { Task { await libraryStore.scan() } }
        if !bootChimePlayed { bootChimePlayed = true; UISoundManager.playBootChime() }
        if let first = libraryStore.consoleGames.first { selectedID = first.id; artworkGameID = first.id }
        focusCoordinator.synchronizeGameCount(games.count)
        librarySnapshotInitialized = true
        focusCoordinator.synchronizeMediaCount(mediaApps.count)
        focusCoordinator.synchronizeBelowFoldRows(cardCounts: [3, max(1, overviewMediaItems.count), 1])
        focusCoordinator.synchronizeMediaBelowFoldRows(cardCounts: mediaRowCounts)
        mediaCoordinator.scan(folders: launcherSettings.mediaFolders.filter(\.enabled).map(\.path))
        libraryModel.synchronize(with: libraryStore.consoleGames)
        libraryStore.enrichConsoleGames(focusedGameID: selectedID)
        updateAmbientMotion()
    }

    private func crossfadeGameArtwork(to id: String) async {
        try? await Task.sleep(nanoseconds: ConsoleMotion.browseDebounceNanoseconds)
        guard !Task.isCancelled else { return }
        withAnimation(launcherSettings.reducedMotion ? .easeOut(duration: 0.1) : .easeInOut(duration: ConsoleMotion.crossfadeDuration)) { artworkGameID = id }
    }

    private func selectedGameChanged(_ id: String) {
        if focusCoordinator.selectedTab == .games { UISoundManager.onGameFocusChanged(id) }
        libraryStore.enrichConsoleGames(focusedGameID: id)
        focusCoordinator.synchronizeBelowFoldRows(cardCounts: [3, max(1, overviewMediaItems.count), 1])
    }

    private func selectedMediaChanged(_ index: Int) {
        guard mediaApps.indices.contains(index) else { return }
        UISoundManager.onGameFocusChanged("media-hub-ambient")
        focusCoordinator.synchronizeMediaBelowFoldRows(cardCounts: mediaRowCounts)
    }

    private func isMediaFocus(_ target: ConsoleFocusTarget) -> Bool {
        switch target {
        case .topBar(.media), .mediaRibbon, .mediaHeroActions, .mediaBelowFold: true
        default: false
        }
    }

    private func mediaAppsChanged(_ count: Int) {
        focusCoordinator.synchronizeMediaCount(count)
        focusCoordinator.synchronizeMediaBelowFoldRows(cardCounts: mediaRowCounts)
    }

    private func handleApplicationActivation(_: Notification) {
        playtimeTracker.recordAllSessionEnds()
        UISoundManager.resumeFromGame()
    }

    private func cleanUpLauncher() {
        inputManager.stop()
        ConsoleToastManager.shared.stop()
        mediaCoordinator.stopPlayer()
        playtimeTracker.recordAllSessionEnds()
    }

    private func libraryGamesChanged() {
        focusCoordinator.synchronizeGameCount(games.count)
        libraryModel.synchronize(with: libraryStore.consoleGames)
        libraryStore.enrichConsoleGames(focusedGameID: selectedID)
    }

    private func updateAmbientMotion(reduced: Bool? = nil, enabled: Bool? = nil) {
        let reduce = reduced ?? launcherSettings.reducedMotion
        let living = enabled ?? launcherSettings.livingBackground
        if reduce || !living || reduceMotion { ambientDrift = false }
        else { withAnimation(.easeInOut(duration: ConsoleMotion.ambientDriftDuration).repeatForever(autoreverses: true)) { ambientDrift = true } }
    }

    private func optionsVisibilityChanged(_ isOpen: Bool) {
        UISoundManager.setOverlayActive(isOpen || focusCoordinator.isSettingsPresented || focusCoordinator.isControlCenterPresented)
        if isOpen { UISoundManager.playOverlayOpen() } else { UISoundManager.playOverlayClose() }
    }

    private func gameArtworkChanged(from oldID: String, to newID: String) {
        fadingArtworkPaths = artworkPaths(for: oldID)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ConsoleMotion.crossfadeDuration * 1_000_000_000))
            guard artworkGameID == newID else { return }
            withAnimation(.easeOut(duration: 0.2)) { fadingArtworkPaths = nil }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(red: 0.025, green: 0.045, blue: 0.105)
            if focusCoordinator.selectedTab == .media {
                MediaAmbientBackdrop(app: selectedMediaApp, drift: ambientDrift)
                    .transition(.opacity)
            } else {
                ZStack {
                    if let fadingArtworkPaths {
                        ConsoleHomeArtwork(paths: fadingArtworkPaths, maxPixelSize: 2200)
                            .id("fade-\(fadingArtworkPaths.first ?? "")")
                            .transition(.opacity)
                    }
                    if !activeArtworkPaths.isEmpty {
                        ConsoleHomeArtwork(paths: activeArtworkPaths, maxPixelSize: 2200)
                            .id(artworkGameID)
                            .transition(.opacity)
                    }
                }
                .scaleEffect((isShowingOverview ? 1.1 : 1.04) + (ambientDrift ? 0.02 : 0))
                .offset(x: ambientDrift ? 9 : -9, y: ambientDrift ? -7 : 7)
                .blur(radius: isShowingOverview ? 12 : 0)
                .animation(.easeInOut(duration: ConsoleMotion.ambientDriftDuration).repeatForever(autoreverses: true), value: ambientDrift)
                .animation(.easeInOut(duration: ConsoleMotion.crossfadeDuration), value: artworkGameID)
            }
            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(isShowingOverview ? 0.82 : 0.88)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.30), .clear],
                           startPoint: .leading, endPoint: .trailing)
            RadialGradient(colors: [.clear, .black.opacity(0.31)], center: .center, startRadius: 260, endRadius: 1250)
            RadialGradient(colors: [.white.opacity(ambientDrift ? 0.055 : 0.025), .clear],
                           center: UnitPoint(x: ambientDrift ? 0.78 : 0.64, y: ambientDrift ? 0.34 : 0.46),
                           startRadius: 12, endRadius: 560)
                .animation(.easeInOut(duration: ConsoleMotion.ambientDriftDuration).repeatForever(autoreverses: true), value: ambientDrift)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 34) {
                tabButton("Games", focus: .topBar(.games), active: focusCoordinator.selectedTab == .games) { focusCoordinator.selectTab(.games) }
                tabButton("Media", focus: .topBar(.media), active: focusCoordinator.selectedTab == .media) { focusCoordinator.selectTab(.media) }
            }
            Spacer()
            HStack(spacing: 22) {
                utilityButton("magnifyingglass", item: .search, label: "Search") { focusCoordinator.openGlobalSearch() }
                utilityButton("gearshape", item: .settings, label: "Settings") {}
                utilityButton("arrow.up.left.and.arrow.down.right", item: .fullscreen, label: "Enter Full Screen") {
                    (NSApp.delegate as? StudioAppDelegate)?.toggleConsoleFullscreen()
                }
                Button {
                    UISoundManager.playLoginConfirm()
                    focusCoordinator.focus(.topBar(.profile))
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(LinearGradient(colors: [Color(red: 0.25, green: 0.64, blue: 0.95), Color(red: 0.19, green: 0.25, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { Text("P1").font(.system(size: 15, weight: .semibold)) }
                            .frame(width: 40, height: 40)
                        Circle().fill(Color(red: 0.32, green: 0.9, blue: 0.58)).frame(width: 9, height: 9).overlay(Circle().stroke(.black.opacity(0.65), lineWidth: 2))
                    }
                    .padding(5)
                    .contentShape(Circle())
                    .overlay { ConsoleSignatureFocusRing(shape: Circle(), isFocused: isFocused(.topBar(.profile))).padding(2) }
                }
                .buttonStyle(.plain).focusEffectDisabled()
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.91))
                        .frame(minWidth: 58, alignment: .trailing)
                        .environment(\.locale, Locale(identifier: launcherSettings.clock24Hour ? "en_GB" : "en_US"))
                }
            }
        }
        .frame(height: 50)
    }

    private func tabButton(_ title: String, focus: ConsoleFocusTarget, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if active { UISoundManager.playConfirm() }
            action()
        } label: {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 19, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? .white : .white.opacity(0.66))
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: isFocused(focus)).padding(1) }
            .overlay(alignment: .bottom) { Capsule().fill(active ? .white.opacity(0.9) : .clear).frame(width: active ? 24 : 0, height: 2).offset(y: 5) }
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func utilityButton(_ symbol: String, item: ConsoleTopBarItem, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.topBar(item))
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(isFocused(.topBar(item)) ? 1 : 0.86))
                .frame(width: 44, height: 44)
                .background(isFocused(.topBar(item)) ? .white.opacity(0.15) : .clear, in: Circle())
        }
        .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(label)
        .overlay { ConsoleSignatureFocusRing(shape: Circle(), isFocused: isFocused(.topBar(item))).padding(2) }
    }

    private func gameRibbon(tileSide: CGFloat, availableWidth: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: max(12, tileSide * 0.085)) {
                    ForEach(games.indices, id: \.self) { index in
                        gameTile(games[index], index: index, side: tileSide)
                            .id(games[index].id)
                    }
                    libraryTile(side: tileSide)
                        .id("__library")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.leading)
            .frame(height: tileSide + 34)
            .onChange(of: selectedID) { _, id in
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo(id, anchor: .leading) }
            }
            .onChange(of: focusTarget) { _, focus in
                guard case .gameRibbon(let index) = focus, index == games.count else { return }
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo("__library", anchor: .trailing) }
            }
        }
        .frame(maxWidth: availableWidth, alignment: .leading)
        .offset(x: boundaryNudge)
        .animation(ConsoleMotion.ribbonSpring, value: boundaryNudge)
        .accessibilityLabel("Game selection")
    }

    private func mediaRibbon(tileSide: CGFloat, availableWidth: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: max(12, tileSide * 0.085)) {
                    ForEach(Array(mediaApps.enumerated()), id: \.element.id) { index, app in
                        mediaTile(app, index: index, side: tileSide).id(app.id)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 16)
            }
            .scrollIndicators(.hidden).defaultScrollAnchor(.leading)
            .frame(height: tileSide + 34)
            .onChange(of: focusTarget) { _, target in
                guard case .mediaRibbon(let index) = target, mediaApps.indices.contains(index) else { return }
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo(mediaApps[index].id, anchor: .leading) }
            }
        }
        .frame(maxWidth: availableWidth, alignment: .leading)
        .offset(x: boundaryNudge)
        .animation(ConsoleMotion.ribbonSpring, value: boundaryNudge)
        .accessibilityLabel("Media app selection")
    }

    private func mediaTile(_ app: ConsoleMediaApp, index: Int, side: CGFloat) -> some View {
        let focused = isFocused(.mediaRibbon(index))
        return Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.mediaRibbon(index))
            if app.id == "all" { mediaCoordinator.launch(app, focus: focusCoordinator) }
            else { focusCoordinator.focus(.mediaHeroActions(.open)) }
        } label: {
            VStack(spacing: 15) {
                Image(systemName: app.symbol)
                    .font(.system(size: side * 0.28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(app.name).font(.system(size: max(12, side * 0.095), weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 14)
            .frame(width: side, height: side)
            .background(LinearGradient(colors: app.colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if app.isCustom { Image(systemName: "link").font(.system(size: 10, weight: .bold)).padding(8).foregroundStyle(.white.opacity(0.78)) }
            }
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(focused ? .clear : .white.opacity(0.16), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 19, style: .continuous), isFocused: focused) }
            .shadow(color: focused ? .white.opacity(0.24) : .black.opacity(0.2), radius: focused ? 18 : 9, y: 6)
            .scaleEffect(focused ? ConsoleMotion.tileFocusScale : 1)
            .opacity(focused ? 1 : ConsoleMotion.tileIdleOpacity)
            .saturation(focused ? 1 : ConsoleMotion.tileIdleSaturation)
            .animation(ConsoleMotion.focusSpring, value: focused)
        }
        .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(app.name)
    }

    private func gameTile(_ game: SampleGame, index: Int, side: CGFloat) -> some View {
        let tileIsFocused = isFocused(.gameRibbon(index))
        return Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.gameRibbon(index))
            focusCoordinator.focus(.heroActions(.play))
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.08))
                ConsoleHomeArtwork(paths: game.tilePaths + (game.wallpaper.imageURL.map { [$0.path] } ?? []), maxPixelSize: 780)
                LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                Image(systemName: game.artwork)
                    .font(.system(size: side * 0.34, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -5)
                Text(game.title)
                    .font(.system(size: max(11, side * 0.09), weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
                if !game.isAvailable {
                    Label("DRIVE NOT CONNECTED", systemImage: "externaldrive.badge.xmark")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(tileIsFocused ? .clear : .white.opacity(0.16), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 19, style: .continuous), isFocused: tileIsFocused) }
            .shadow(color: tileIsFocused ? .white.opacity(0.27) : .black.opacity(0.2), radius: tileIsFocused ? 19 : 9, y: 6)
            .scaleEffect(tileIsFocused ? ConsoleMotion.tileFocusScale : 1)
            .opacity(game.isAvailable ? (tileIsFocused ? 1 : ConsoleMotion.tileIdleOpacity) : (tileIsFocused ? 0.76 : 0.54))
            .saturation(tileIsFocused ? 1 : ConsoleMotion.tileIdleSaturation)
            .animation(ConsoleMotion.focusSpring, value: tileIsFocused)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(game.title)
    }

    private func libraryTile(side: CGFloat) -> some View {
        let tileIsFocused = isFocused(.gameRibbon(games.count))
        return Button {
            focusCoordinator.focus(.gameRibbon(games.count))
            focusCoordinator.handle(.confirm)
        } label: {
            VStack(spacing: 13) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: side * 0.27, weight: .light))
                Text("Game Library").font(.system(size: max(12, side * 0.095), weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.84))
            .frame(width: side, height: side)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(tileIsFocused ? .clear : .white.opacity(0.18), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 19, style: .continuous), isFocused: tileIsFocused) }
            .scaleEffect(tileIsFocused ? ConsoleMotion.tileFocusScale : 1)
            .opacity(tileIsFocused ? 1 : ConsoleMotion.tileIdleOpacity)
            .animation(ConsoleMotion.focusSpring, value: tileIsFocused)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func heroZone(compact: Bool) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: compact ? 12 : 17) {
                Text(libraryHeroOverride?.developer.uppercased() ?? selectedGame.subtitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .tracking(2.0)
                    .foregroundStyle(.white.opacity(0.77))
                if let logoPath = libraryHeroOverride?.localLogoPath ?? selectedGame.localLogoPath,
                   let logo = NSImage(contentsOfFile: logoPath) {
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 88, alignment: .leading)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 3)
                        .accessibilityLabel(libraryHeroOverride?.title ?? selectedGame.title)
                } else {
                    Text(libraryHeroOverride?.title ?? selectedGame.title)
                        .font(.system(size: compact ? 43 : 57, weight: .medium, design: .default))
                        .tracking(-1.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .shadow(color: .black.opacity(0.28), radius: 12, y: 3)
                        .contentTransition(.opacity)
                }
                if let summary = libraryHeroOverride?.summary ?? selectedGame.summary {
                    Text(summary).font(.system(size: 16, weight: .regular)).foregroundStyle(.white.opacity(0.76))
                        .lineLimit(3).frame(maxWidth: 690, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Button {
                        UISoundManager.playConfirm()
                        focusCoordinator.focus(.heroActions(.play))
                        launchSelectedGame()
                    } label: {
                        let playIsFocused = isFocused(.heroActions(.play))
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(playIsFocused ? Color(red: 0.055, green: 0.075, blue: 0.12) : .white)
                            .padding(.horizontal, 31)
                            .frame(height: 54)
                            .background {
                                if playIsFocused { Capsule().fill(.white) }
                                else { Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(.white.opacity(0.12))) }
                            }
                            .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: playIsFocused).padding(-4) }
                            .overlay(Capsule().strokeBorder(.white.opacity(playIsFocused ? 0.9 : 0.38), lineWidth: 1))
                            .shadow(color: playIsFocused ? .white.opacity(0.28) : .clear, radius: 16)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    Button {
                        UISoundManager.playConfirm()
                        focusCoordinator.focus(.heroActions(.options))
                        showingOptions = true
                    } label: {
                        let optionsIsFocused = isFocused(.heroActions(.options))
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().fill(.white.opacity(0.09)).padding(1))
                            .overlay { ConsoleSignatureFocusRing(shape: Circle(), isFocused: optionsIsFocused).padding(-3) }
                            .overlay(Circle().strokeBorder(.white.opacity(optionsIsFocused ? 0.9 : 0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel("More options")
                }
                .padding(.top, 1)
            }
            .frame(maxWidth: 770, alignment: .leading)
            Spacer(minLength: 50)
            let activity = activePlaytime
            VStack(alignment: .trailing, spacing: 10) {
                Label("Last played  \(activity.lastPlayedDate?.formatted(date: .abbreviated, time: .omitted) ?? selectedGame.lastPlayed)", systemImage: "clock")
                Text("\(Int(activity.totalSecondsPlayed / 3_600))h Played")
                HStack(spacing: 9) {
                    Text("Progress")
                    ProgressView(value: selectedGame.progress).tint(.white).frame(width: 92)
                    Text("\(Int(selectedGame.progress * 100))%")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.76))
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
        .animation(ConsoleMotion.focusSpring, value: selectedID)
    }

    private func mediaHero(compact: Bool) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                Text("MEDIA HUB")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).tracking(2.1)
                    .foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 15) {
                    Image(systemName: selectedMediaApp.symbol).font(.system(size: compact ? 27 : 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(selectedMediaApp.name).font(.system(size: compact ? 43 : 57, weight: .medium))
                        .tracking(-1.8).lineLimit(1).minimumScaleFactor(0.75).shadow(color: .black.opacity(0.28), radius: 12, y: 3)
                }
                Text(selectedMediaApp.subtitle).font(.system(size: 16)).foregroundStyle(.white.opacity(0.76))
                HStack(spacing: 14) {
                    Button {
                        UISoundManager.playConfirm()
                        focusCoordinator.focus(.mediaHeroActions(.open))
                        mediaCoordinator.launch(selectedMediaApp, focus: focusCoordinator)
                    } label: {
                        let focused = isFocused(.mediaHeroActions(.open))
                        Label("Open", systemImage: "play.fill").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(focused ? Color(red: 0.055, green: 0.075, blue: 0.12) : .white)
                            .padding(.horizontal, 31).frame(height: 54)
                            .background(focused ? Color.white : Color.white.opacity(0.16), in: Capsule())
                            .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: focused).padding(-4) }
                            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.9 : 0.38), lineWidth: 1))
                            .shadow(color: focused ? .white.opacity(0.26) : .clear, radius: 15)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    Button {
                        UISoundManager.playConfirm()
                        focusCoordinator.focus(.mediaHeroActions(.options))
                        focusCoordinator.presentMediaModal(.appManager)
                    } label: {
                        let focused = isFocused(.mediaHeroActions(.options))
                        Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                            .overlay { ConsoleSignatureFocusRing(shape: Circle(), isFocused: focused).padding(-3) }
                            .overlay(Circle().strokeBorder(.white.opacity(focused ? 0.9 : 0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel("Media app options")
                }
            }
            .frame(maxWidth: 770, alignment: .leading)
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 9) {
                Label(selectedMediaApp.isCustom ? "Custom destination" : "Ready to open", systemImage: "dot.radiowaves.left.and.right")
                Text(selectedMediaApp.name == "Local Media" ? "\(mediaCoordinator.videos.count) local videos" : "Controller and keyboard ready")
            }
            .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.74))
            .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
        .animation(ConsoleMotion.focusSpring, value: selectedMediaApp.id)
    }

    private func mediaShelfItems(row: Int) -> [ConsoleMediaShelfItem] {
        switch selectedMediaApp.id {
        case "local":
            let items = row == 0 ? continueWatchingVideos : mediaCoordinator.videos
            let cards = items.map { video in
                let progress = mediaCoordinator.savedProgress(for: video.id)
                return ConsoleMediaShelfItem(id: video.id, title: video.title,
                    subtitle: row == 0 ? "Continue · \(max(0, video.duration - progress).mediaClock) left" : video.duration.mediaClock,
                    symbol: "play.fill", thumbnailPath: video.thumbnailPath, video: video, isProgressCard: row == 0)
            }
            return cards.isEmpty ? [ConsoleMediaShelfItem(id: "empty-\(row)", title: row == 0 ? "Nothing in progress" : "No local videos found", subtitle: row == 0 ? "Your viewing progress will appear here." : "Add a folder under Settings → Game Paths → Media Folders.", symbol: "film") ] : cards
        case "youtube":
            let channels: [(String, String, String)] = [("Channels", "youtube.com/@linustechtips", "tv"), ("Channels", "youtube.com/@mkiceandfire", "gamecontroller"), ("Channels", "youtube.com/@Kurzgesagt", "sparkles"), ("Channels", "youtube.com/@NASA", "globe")]
            let playlists: [(String, String, String)] = [("Playlists", "youtube.com/playlist?list=PL", "music.note.list"), ("Playlists", "youtube.com/feed/playlists", "rectangle.stack"), ("Playlists", "youtube.com/playlist?list=PLfilms", "film"), ("Playlists", "youtube.com/feed/history", "clock")]
            let values = row == 0 ? channels : playlists
            return values.enumerated().map { index, item in
                ConsoleMediaShelfItem(id: "youtube-\(row)-\(index)", title: item.1.replacingOccurrences(of: "youtube.com/", with: ""), subtitle: row == 0 ? "Pinned channel" : "Pinned playlist", symbol: item.2,
                                      launchURL: URL(string: "https://\(item.1)") )
            }
        case "all":
            return [ConsoleMediaShelfItem(id: "manage-apps", title: "Manage Media Apps", subtitle: "Show, hide, and add destinations", symbol: "slider.horizontal.3")]
        default:
            return [ConsoleMediaShelfItem(id: "open-\(selectedMediaApp.id)", title: "Open \(selectedMediaApp.name)", subtitle: selectedMediaApp.subtitle, symbol: selectedMediaApp.symbol)]
        }
    }

    private func mediaOverview(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedMediaApp.name).font(.system(size: 25, weight: .medium, design: .rounded)).lineLimit(1)
                    Text("MEDIA HUB").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    UISoundManager.playConfirm()
                    mediaCoordinator.launch(selectedMediaApp, focus: focusCoordinator)
                } label: {
                    Label("Open", systemImage: "play.fill").font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 20).frame(height: 42)
                        .foregroundStyle(Color(red: 0.055, green: 0.075, blue: 0.12)).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            ScrollViewReader { verticalReader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(Array(mediaRowCounts.indices), id: \.self) { row in
                            mediaShelfRow(row: row, cards: mediaShelfItems(row: row))
                                .id("media-row-\(row)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusTarget) { _, target in
                    guard case .mediaBelowFold(let row, _) = target else { return }
                    withAnimation(ConsoleMotion.ribbonSpring) { verticalReader.scrollTo("media-row-\(row)", anchor: .center) }
                }
            }
            HStack(spacing: 9) {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                Text("Return to Open")
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func mediaShelfRow(row: Int, cards: [ConsoleMediaShelfItem]) -> some View {
        let title: String = switch selectedMediaApp.id {
        case "local": row == 0 ? "Continue Watching" : "All Local Videos"
        case "youtube": row == 0 ? "Pinned Channels" : "Pinned Playlists"
        case "all": "Media Apps"
        default: "Quick Launch"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.58))
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 13) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, item in
                            mediaShelfCard(row: row, index: index, item: item)
                                .id("media-card-\(row)-\(index)")
                        }
                    }
                    .padding(.horizontal, 3).padding(.vertical, 8)
                    .offset(x: boundaryNudge)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusTarget) { _, target in
                    guard case .mediaBelowFold(let activeRow, let index) = target, activeRow == row else { return }
                    withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo("media-card-\(row)-\(index)", anchor: .center) }
                }
            }
        }
        .frame(height: 205)
    }

    private func mediaShelfCard(row: Int, index: Int, item: ConsoleMediaShelfItem) -> some View {
        let focused = isFocused(.mediaBelowFold(row: row, index: index))
        return Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.mediaBelowFold(row: row, index: index))
            activateMediaShelf(row: row, index: index)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    if let path = item.thumbnailPath { ConsoleHomeArtwork(paths: [path], maxPixelSize: 960) }
                    else {
                        RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: selectedMediaApp.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: item.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(item.subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .padding(12)
                }
                .frame(width: 286, height: 144).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                if item.isProgressCard, let video = item.video {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.17))
                            Capsule().fill(.white).frame(width: proxy.size.width * (video.duration > 0 ? min(1, mediaCoordinator.savedProgress(for: video.id) / video.duration) : 0))
                        }
                    }.frame(width: 286, height: 3)
                } else { Spacer(minLength: 0).frame(height: 3) }
            }
            .padding(8).frame(width: 302, height: 176, alignment: .topLeading)
            .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? .clear : .white.opacity(0.13), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: focused) }
            .shadow(color: focused ? .white.opacity(0.18) : .black.opacity(0.14), radius: focused ? 15 : 7, y: 5)
            .scaleEffect(focused ? ConsoleMotion.activityFocusScale : 1)
            .animation(ConsoleMotion.focusSpring, value: focused)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func activateMediaShelf(row: Int, index: Int) {
        let item = mediaShelfItems(row: row).indices.contains(index) ? mediaShelfItems(row: row)[index] : nil
        guard let item else { return }
        if let video = item.video { mediaCoordinator.play(video, focus: focusCoordinator) }
        else if let url = item.launchURL {
            mediaCoordinator.openWeb(url, focus: focusCoordinator)
        } else if selectedMediaApp.id == "all" {
            focusCoordinator.presentMediaModal(.appManager)
        } else {
            mediaCoordinator.launch(selectedMediaApp, focus: focusCoordinator)
        }
    }

    private func overview(size: CGSize) -> some View {
        let hours = Int(activePlaytime.totalSecondsPlayed / 3_600)
        let lastSession = activePlaytime.lastSession
        let statCards = [
            OverviewCard(id: 0, title: "\(hours)h Played", detail: "Across \(activePlaytime.launchCount) sessions", symbol: "clock.fill", badge: "PLAY ACTIVITY"),
            OverviewCard(id: 1, title: activePlaytime.lastPlayedDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not played yet",
                         detail: "\(Int((lastSession?.durationSeconds ?? 0) / 60)) min last session · \(activePlaytime.launchCount) launches",
                         symbol: "clock.arrow.circlepath", badge: "LAST SESSION"),
            OverviewCard(id: 2, title: selectedGame.platforms.first ?? selectedGame.subtitle,
                         detail: selectedGame.installLocation.map { "Installed in \($0)" } ?? "Quick launch and game information",
                         symbol: "gamecontroller.fill", badge: "QUICK LAUNCH")
        ]
        let mediaCards = overviewMediaItems.isEmpty ? [OverviewCard(id: 0, title: "No media yet", detail: "Trailers and screenshots appear here when GameDB has them.", symbol: "photo.on.rectangle", badge: "MEDIA GALLERY")] : overviewMediaItems.enumerated().map { index, item in
            switch item {
            case .trailer(let video): OverviewCard(id: index, title: video.title, detail: "Watch trailer", symbol: "play.fill", badge: "TRAILER")
            case .screenshot: OverviewCard(id: index, title: "Screenshot \(index + 1)", detail: "View full screen", symbol: "photo", badge: "SCREENSHOT")
            }
        }
        let summaryText = selectedGame.summary ?? "Game details are not available yet."
        let summaryCard = [OverviewCard(id: 0, title: "About \(selectedGame.title)", detail: summaryText, symbol: "text.alignleft", badge: "ABOUT THIS GAME")]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedGame.title).font(.system(size: 25, weight: .medium, design: .rounded)).lineLimit(1)
                    Text("GAME HUB").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    UISoundManager.playConfirm()
                    launchSelectedGame()
                } label: {
                    Label("Play", systemImage: "play.fill").font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 20).frame(height: 42)
                        .foregroundStyle(Color(red: 0.055, green: 0.075, blue: 0.12))
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            ScrollViewReader { verticalReader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 15) {
                        overviewRow(row: 0, title: "Play Activity", cards: statCards, height: 145)
                            .id("hub-row-0")
                        mediaRow(cards: mediaCards, height: 166)
                            .id("hub-row-1")
                        overviewRow(row: 2, title: "About & Details", cards: summaryCard, height: 174, wide: true)
                            .id("hub-row-2")
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusTarget) { _, target in
                    guard case .belowFold(let row, _) = target else { return }
                    withAnimation(ConsoleMotion.ribbonSpring) { verticalReader.scrollTo("hub-row-\(row)", anchor: .center) }
                }
            }
            HStack(spacing: 9) {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                Text("Return to Play")
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.62))
            .padding(.top, 1)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func overviewRow(row: Int, title: String, cards: [OverviewCard], height: CGFloat, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.58))
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 13) {
                        ForEach(cards) { card in
                            overviewCard(row: row, card: card, width: wide ? 930 : 265, height: height,
                                weeklyActivity: row == 0 && card.id == 0)
                                .id("hub-card-\(row)-\(card.id)")
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 3)
                    .offset(x: boundaryNudge)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusTarget) { _, target in
                    guard case .belowFold(let activeRow, let index) = target, activeRow == row else { return }
                    withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo("hub-card-\(row)-\(index)", anchor: .center) }
                }
            }
        }
        .frame(height: height + 25)
    }

    private func mediaRow(cards: [OverviewCard], height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEDIA GALLERY").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.58))
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 13) {
                        ForEach(cards) { card in
                            mediaCard(card, width: 275, height: height)
                                .id("hub-card-1-\(card.id)")
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 3)
                    .offset(x: boundaryNudge)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusTarget) { _, target in
                    guard case .belowFold(let row, let index) = target, row == 1 else { return }
                    withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo("hub-card-1-\(index)", anchor: .center) }
                }
            }
        }
        .frame(height: height + 25)
    }

    private func overviewCard(row: Int, card: OverviewCard, width: CGFloat, height: CGFloat, weeklyActivity: Bool = false) -> some View {
        let focused = isFocused(.belowFold(row: row, index: card.id))
        return Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.belowFold(row: row, index: card.id))
            if row == 2 { openSummaryReader() }
            else if row == 0 && card.id == 2 { focusCoordinator.focus(.heroActions(.play)) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: card.symbol).font(.system(size: 18, weight: .medium))
                    Spacer()
                    if weeklyActivity {
                        ZStack {
                            Circle().stroke(.white.opacity(0.16), lineWidth: 3)
                            Circle().trim(from: 0, to: min(1, activePlaytime.weeklySeconds / (7 * 3_600)))
                                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        .frame(width: 31, height: 31)
                    } else {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.52))
                    }
                }
                Text(card.badge).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.52))
                Text(card.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(card.detail)
                    .font(.system(size: row == 2 ? 14 : 12, weight: .medium))
                    .lineSpacing(row == 2 ? 4 : 0)
                    .foregroundStyle(.white.opacity(0.71))
                    .lineLimit(row == 2 ? 4 : 2)
                if row == 2 {
                    HStack(spacing: 9) {
                        if let year = selectedGame.releaseYear { metadataPill("\(year)") }
                        if let developer = selectedGame.developers.first { metadataPill(developer) }
                        if let publisher = selectedGame.publishers.first { metadataPill(publisher) }
                        if let genre = selectedGame.genres.first { metadataPill(genre) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(17)
            .frame(width: width, height: height, alignment: .leading)
            .background(.ultraThinMaterial.opacity(0.48), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? .clear : .white.opacity(0.14), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: focused) }
            .shadow(color: focused ? .white.opacity(0.17) : .black.opacity(0.14), radius: focused ? 15 : 7, y: 5)
            .scaleEffect(focused ? ConsoleMotion.activityFocusScale : 1)
            .animation(ConsoleMotion.focusSpring, value: focused)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel("\(card.title), \(card.detail)")
    }

    private func mediaCard(_ card: OverviewCard, width: CGFloat, height: CGFloat) -> some View {
        let focused = isFocused(.belowFold(row: 1, index: card.id))
        return Button {
            UISoundManager.playConfirm()
            focusCoordinator.focus(.belowFold(row: 1, index: card.id))
            openMediaItem(at: card.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .center) {
                    mediaArtwork(at: card.id)
                    LinearGradient(colors: [.clear, .black.opacity(0.64)], startPoint: .center, endPoint: .bottom)
                    if isTrailer(at: card.id) {
                        Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold))
                            .padding(13).background(.black.opacity(0.45), in: Circle()).overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                    }
                    Text(card.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12)
                }
                .frame(width: width, height: height - 42)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(card.badge).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.58))
            }
            .padding(8)
            .frame(width: width + 16, height: height, alignment: .topLeading)
            .background(.ultraThinMaterial.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? .clear : .white.opacity(0.14), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: focused) }
            .shadow(color: focused ? .white.opacity(0.18) : .black.opacity(0.14), radius: focused ? 16 : 7, y: 5)
            .scaleEffect(focused ? ConsoleMotion.activityFocusScale : 1)
            .animation(ConsoleMotion.focusSpring, value: focused)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    @ViewBuilder private func mediaArtwork(at index: Int) -> some View {
        if overviewMediaItems.indices.contains(index) {
            switch overviewMediaItems[index] {
            case .trailer(let video):
                if let path = video.thumbnailPath { ConsoleHomeArtwork(paths: [path], maxPixelSize: 640) }
                else {
                    AsyncImage(url: URL(string: video.thumbnailURL)) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.07) }
                }
            case .screenshot(let path): ConsoleHomeArtwork(paths: [path], maxPixelSize: 640)
            }
        } else {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
        }
    }

    private func isTrailer(at index: Int) -> Bool {
        guard overviewMediaItems.indices.contains(index) else { return false }
        if case .trailer = overviewMediaItems[index] { return true }
        return false
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.09), in: Capsule())
    }

    private func openMediaItem(at index: Int) {
        guard overviewMediaItems.indices.contains(index) else { return }
        switch overviewMediaItems[index] {
        case .trailer(let video): focusCoordinator.presentOverviewModal(.trailer(video))
        case .screenshot: focusCoordinator.presentOverviewModal(.screenshot(title: selectedGame.title, paths: selectedGame.screenshotPaths, index: index - selectedGame.videos.count))
        }
    }

    private func openSummaryReader() {
        guard let summary = selectedGame.summary else { return }
        focusCoordinator.presentOverviewModal(.summary(title: selectedGame.title, summary: summary, storyline: selectedGame.storyline))
    }

    private var mediaLanding: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Media Gallery").font(.system(size: 52, weight: .medium, design: .rounded)).tracking(-1.4)
            Text("Your captures and moments, all in one place.")
                .font(.system(size: 19)).foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                Text("No captures yet")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.top, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsScrim: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture { showingOptions = false }
            VStack(alignment: .leading, spacing: 20) {
                Text("Game Options").font(.system(size: 22, weight: .semibold))
                Label("View Product", systemImage: "info.circle")
                Label("Manage Game Content", systemImage: "square.stack.3d.up")
                Label("Remove from Home", systemImage: "minus.circle")
                Text("Press Esc to close").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 16, weight: .medium))
            .padding(28)
            .frame(width: 350, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.2)))
        }
    }

    private func configureConsoleNavigation() {
        focusCoordinator.onFocusChanged = { target in
            UISoundManager.playFocusMove()
            if case .gameRibbon(let index) = target, games.indices.contains(index) {
                libraryHeroOverride = nil
                selectedID = games[index].id
            }
            if focusCoordinator.selectedTab == .media && isMediaFocus(target) {
                UISoundManager.onGameFocusChanged("media-hub-ambient")
            }
        }
        focusCoordinator.onTabSwitch = { UISoundManager.playTabSwitch() }
        focusCoordinator.onBoundaryBump = playBoundaryBump
        focusCoordinator.onConfirm = activate
        focusCoordinator.onBack = { UISoundManager.playBack() }
        focusCoordinator.onSettingsStateChanged = { isOpen in
            UISoundManager.setOverlayActive(isOpen || focusCoordinator.isControlCenterPresented || showingOptions)
            if isOpen { UISoundManager.playOverlayOpen() } else { UISoundManager.playOverlayClose() }
        }
        focusCoordinator.onSettingsFocusMove = { UISoundManager.playFocusMove() }
        focusCoordinator.onSettingsSelect = { _, _ in UISoundManager.playConfirm() }
        focusCoordinator.onOptions = {
            UISoundManager.playConfirm()
            showingOptions = true
        }
        focusCoordinator.onControlCenterChanged = { isOpen in
            UISoundManager.setOverlayActive(isOpen || focusCoordinator.isSettingsPresented || showingOptions)
            if isOpen { UISoundManager.playOverlayOpen() } else { UISoundManager.playOverlayClose() }
        }
        focusCoordinator.onControlCardChanged = { isOpen in
            if isOpen { UISoundManager.playConfirm() }
            else { UISoundManager.playBack() }
        }
        focusCoordinator.onControlCenterFocusMove = { UISoundManager.playFocusMove() }
        focusCoordinator.onControlCenterBack = { UISoundManager.playBack() }
        focusCoordinator.onVolumeChanged = { value in
            SystemVolumeController.set(value)
            UISoundManager.playSliderTick()
        }
        focusCoordinator.onAudioOutputChanged = { _ in }
        focusCoordinator.onControlCardConfirm = { card, index in
            UISoundManager.playConfirm()
            if card == .sound, index == 1 { focusCoordinator.moveAudioOutput(by: 1) }
        }
        focusCoordinator.onPowerAction = { _ in }
        focusCoordinator.onLibraryStateChanged = { isOpen in
            if isOpen {
                UISoundManager.playOverlayOpen()
                libraryHeroOverride = nil
                libraryModel.searchText = ""
            } else {
                UISoundManager.playOverlayClose()
            }
        }
        focusCoordinator.onLibraryFocusMove = { _ in UISoundManager.playFocusMove() }
        focusCoordinator.onLibrarySearchChanged = { inputManager.textEntryActive = $0 }
        focusCoordinator.onOverviewModalChanged = { isOpen in
            UISoundManager.setOverlayActive(isOpen || focusCoordinator.isSettingsPresented || focusCoordinator.isControlCenterPresented || focusCoordinator.isLibraryPresented || showingOptions)
            if isOpen { UISoundManager.playOverlayOpen() } else { UISoundManager.playOverlayClose() }
        }
        focusCoordinator.onOverviewModalFocusMove = { UISoundManager.playFocusMove() }
        focusCoordinator.onMediaConfirm = { target in activateMedia(target) }
        focusCoordinator.onMediaModalAction = { action in
            switch action {
            case .confirm: UISoundManager.playConfirm()
            case .back, .home: UISoundManager.playBack()
            case .move(.left), .move(.right):
                if focusCoordinator.activeMediaModal == .localVideoPlayer { UISoundManager.playSliderTick() }
                else { UISoundManager.playFocusMove() }
            case .move(.up), .move(.down): UISoundManager.playFocusMove()
            case .options, .tabLeft, .tabRight, .search: UISoundManager.playFocusMove()
            }
            mediaCoordinator.handleModalAction(action, focus: focusCoordinator, input: inputManager)
        }
        focusCoordinator.onMediaModalChanged = { isOpen in
            if isOpen { UISoundManager.playOverlayOpen() } else { UISoundManager.playOverlayClose() }
        }
        focusCoordinator.onMediaModalFocusMove = { UISoundManager.playFocusMove() }
        focusCoordinator.onGlobalSearchStateChanged = { isOpen in
            inputManager.globalSearchEntryActive = isOpen
            if !isOpen { inputManager.globalSearchCaretActive = false }
            UISoundManager.setOverlayActive(isOpen || focusCoordinator.isSettingsPresented || focusCoordinator.isControlCenterPresented || showingOptions)
        }
        focusCoordinator.onGlobalSearchFocusMove = {
            inputManager.globalSearchCaretActive = focusCoordinator.globalSearchRegion == .searchBar
            UISoundManager.playFocusMove()
        }
        focusCoordinator.onGlobalSearchFilterChanged = { _ in UISoundManager.playTabSwitch() }
        focusCoordinator.onGlobalSearchKey = { key in handleGlobalSearchKey(key) }
        focusCoordinator.onGlobalSearchBack = {
            guard !globalSearchQuery.isEmpty else { return false }
            globalSearchQuery = ""
            return true
        }
        focusCoordinator.onGlobalSearchConfirm = { index in
            if globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard recentSearches.indices.contains(index) else { return }
                useRecentSearch(recentSearches[index])
            } else {
                selectGlobalSearchResult(index)
            }
        }
        inputManager.onAction = { action in
            if focusCoordinator.isGlobalSearchPresented {
                focusCoordinator.handle(action)
            } else if focusCoordinator.isControlCenterPresented {
                focusCoordinator.handle(action)
            } else if action == .back, showingOptions {
                UISoundManager.playBack()
                showingOptions = false
            } else {
                focusCoordinator.handle(action)
            }
        }
    }

    private func activate(_ target: ConsoleFocusTarget) {
        UISoundManager.playConfirm()
        switch target {
        case .topBar(.search): focusCoordinator.openGlobalSearch()
        case .topBar(.games): focusCoordinator.selectTab(.games)
        case .topBar(.media): focusCoordinator.selectTab(.media)
        case .topBar(.fullscreen): (NSApp.delegate as? StudioAppDelegate)?.toggleConsoleFullscreen()
        case .topBar(.settings): focusCoordinator.openSettings()
        case .topBar(_): break
        case .belowFold(let row, let index):
            if row == 1 { openMediaItem(at: index) }
            else if row == 2 { openSummaryReader() }
            else if index == 2 { focusCoordinator.focus(.heroActions(.play)) }
        case .gameRibbon(let index):
            if index == games.count {
                focusCoordinator.openLibrary(itemCount: libraryModel.games.filter(\.isInstalled).count, columns: 5)
            } else if games.indices.contains(index) {
                focusCoordinator.focus(.heroActions(.play))
            }
        case .heroActions(.options): showingOptions = true
        case .heroActions(.play):
            launchSelectedGame()
        case .mediaRibbon(let index):
            guard mediaApps.indices.contains(index) else { return }
            mediaCoordinator.launch(mediaApps[index], focus: focusCoordinator)
        case .mediaHeroActions(.open):
            mediaCoordinator.launch(selectedMediaApp, focus: focusCoordinator)
        case .mediaHeroActions(.options):
            focusCoordinator.presentMediaModal(.appManager)
        case .mediaBelowFold(let row, let index):
            activateMediaShelf(row: row, index: index)
        }
    }

    private func activateMedia(_ target: ConsoleFocusTarget) {
        UISoundManager.playConfirm()
        switch target {
        case .mediaRibbon(let index):
            guard mediaApps.indices.contains(index) else { return }
            if mediaApps[index].id == "all" { focusCoordinator.presentMediaModal(.appManager) }
            else { focusCoordinator.focus(.mediaHeroActions(.open)) }
        case .mediaHeroActions(.open): mediaCoordinator.launch(selectedMediaApp, focus: focusCoordinator)
        case .mediaHeroActions(.options): focusCoordinator.presentMediaModal(.appManager)
        case .mediaBelowFold(let row, let index): activateMediaShelf(row: row, index: index)
        default: break
        }
    }

    private func handleGlobalSearchKey(_ key: String) {
        switch key {
        case "Space": globalSearchQuery.append(" ")
        case "Backspace": if !globalSearchQuery.isEmpty { globalSearchQuery.removeLast() }
        case "Clear": globalSearchQuery = ""
        case "Done": focusCoordinator.focusGlobalSearchResults()
        default: globalSearchQuery.append(key)
        }
    }

    private func useRecentSearch(_ value: String) {
        globalSearchQuery = value
        focusCoordinator.focusGlobalSearchResults()
        UISoundManager.playConfirm()
    }

    private func rememberGlobalSearch() {
        let value = globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
        recentSearches.insert(value, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "console.search.recent.player-1")
    }

    private func selectGlobalSearchResult(_ index: Int) {
        guard globalSearchResults.indices.contains(index) else { return }
        rememberGlobalSearch()
        let result = globalSearchResults[index]
        focusCoordinator.closeGlobalSearch()
        switch result.kind {
        case .game:
            guard let gameIndex = games.firstIndex(where: { $0.id == result.id }) else { return }
            selectedID = result.id
            focusCoordinator.selectTab(.games)
            focusCoordinator.focus(.gameRibbon(gameIndex))
        case .mediaApp:
            guard let mediaIndex = mediaApps.firstIndex(where: { $0.id == result.id }) else { return }
            focusCoordinator.focus(.mediaRibbon(mediaIndex))
            mediaCoordinator.launch(mediaApps[mediaIndex], focus: focusCoordinator)
        case .video:
            guard let video = mediaCoordinator.videos.first(where: { $0.id == result.id }) else { return }
            focusCoordinator.selectTab(.media)
            mediaCoordinator.play(video, focus: focusCoordinator)
        case .setting:
            let parts = result.id.split(separator: ":")
            guard parts.count >= 2, let raw = Int(parts[1]), let category = ConsoleSettingsCategory(rawValue: raw) else { return }
            focusCoordinator.openSettings()
            focusCoordinator.chooseSettingsCategory(category)
        }
    }

    private func showLibraryGameInHero(_ game: ConsoleLibraryGame) {
        libraryHeroOverride = game
        selectedID = game.heroGameID
        focusCoordinator.closeLibrary()
        focusCoordinator.focus(.heroActions(.play))
    }

    private func applyNavigationPreferences() {
        inputManager.stickDeadzone = Float(launcherSettings.stickDeadzone)
        applyRepeatSpeed(launcherSettings.repeatSpeed)
        UISoundManager.soundEffectsEnabled = launcherSettings.uiSoundEffects
        UISoundManager.soundEffectsVolume = Float(launcherSettings.uiSoundVolume)
        UISoundManager.onGameFocusChanged(selectedID)
    }

    private func applyRepeatSpeed(_ speed: String) {
        inputManager.holdRepeatInterval = switch speed {
        case "Relaxed": 0.14
        case "Fast": 0.085
        default: 0.102
        }
    }

    private func handlePowerAction(_ index: Int) {
        UISoundManager.playConfirm()
        if shellCoordinator.activeExternalAppTitle != nil {
            switch index {
            case 0: shellCoordinator.resumeExternalApp()
            case 1: shellCoordinator.closeActiveExternalApp()
            case 2: shellCoordinator.exitToDesktop()
            case 3: break // macOS sleep is intentionally left to the system power policy.
            case 4:
                showingOptions = false
                selectedID = "horizon"
                focusCoordinator.resetLauncher()
            default: break
            }
            return
        }
        switch index {
        case 0:
            shellCoordinator.exitToDesktop()
        case 1:
            break
        case 2:
            showingOptions = false
            selectedID = "horizon"
            focusCoordinator.resetLauncher()
        default:
            break
        }
    }

    private func launchSelectedGame() {
        guard let game = libraryStore.data.games.first(where: { $0.id == selectedID }) else {
            ConsoleToastManager.shared.post("No Games Found", "Add a game folder in System Settings, then choose Scan Library Now.", symbol: "gamecontroller", priority: .normal)
            return
        }
        gameLaunchCoordinator.launch(game, through: libraryStore)
    }

    private func launchLibraryGame(_ game: ConsoleLibraryGame) {
        guard let entry = libraryStore.data.games.first(where: { $0.id == game.id }) else { return }
        focusCoordinator.closeLibrary()
        selectedID = entry.id
        gameLaunchCoordinator.launch(entry, through: libraryStore)
    }

    private func isFocused(_ target: ConsoleFocusTarget) -> Bool {
        !focusCoordinator.isControlCenterPresented && focusTarget == target
    }

    private func playBoundaryBump(_ direction: ConsoleDirection) {
        UISoundManager.playBoundaryBump()
        withAnimation(.spring(response: 0.16, dampingFraction: 0.34)) {
            boundaryNudge = direction == .left ? 9 : direction == .right ? -9 : direction == .up ? 7 : -7
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(ConsoleMotion.ribbonSpring) { boundaryNudge = 0 }
        }
    }
}

private struct MediaAmbientBackdrop: View {
    let app: ConsoleMediaApp
    let drift: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: app.colors.map { $0.opacity(0.74) } + [Color(red: 0.015, green: 0.025, blue: 0.07)], startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [app.colors.first?.opacity(0.48) ?? .white.opacity(0.15), .clear],
                           center: UnitPoint(x: drift ? 0.73 : 0.62, y: drift ? 0.32 : 0.44), startRadius: 30, endRadius: 800)
            Image(systemName: app.symbol)
                .font(.system(size: 360, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.07))
                .rotationEffect(.degrees(drift ? -5 : 3))
                .offset(x: drift ? 170 : 210, y: drift ? -35 : 20)
                .blur(radius: 1)
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.64), .black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
            RadialGradient(colors: [.clear, .black.opacity(0.28)], center: .center, startRadius: 280, endRadius: 1250)
        }
        .scaleEffect(drift ? 1.04 : 1.02)
        .animation(.easeInOut(duration: ConsoleMotion.ambientDriftDuration).repeatForever(autoreverses: true), value: drift)
        .animation(.easeInOut(duration: ConsoleMotion.crossfadeDuration), value: app.id)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
