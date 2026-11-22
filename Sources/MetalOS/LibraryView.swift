import SwiftUI
import AppKit

@MainActor var studioAccent: Color { StudioAppearance.shared.accent }
@MainActor var studioBackground: Color { StudioAppearance.shared.background }

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var controller = ControllerManager.shared
    @State private var appsPage = false
    @State private var libraryPage = false
    @State private var storeAppPage = false
    @State private var browserPage = false
    @StateObject private var browserSession = InAppBrowserSession()
    @StateObject private var epicStoreBrowserSession = InAppBrowserSession()
    @StateObject private var gogStoreBrowserSession = InAppBrowserSession()
    @StateObject private var storefrontRuntime = WindowsStorefrontRuntime()
    @StateObject private var switchAppInstaller = NXNativeInstaller()
    @StateObject private var windowsClientInstaller = WindowsClientInstaller()
    @State private var selectedStoreCatalogIndex = 0
    @State private var selectedPlatformAppIndex = 0
    @State private var pendingPlatformInstall: PlatformApp?
    @State private var showSwitchRequirementsConfirmation = false
    @State private var launchWindowsInstallerFlow = false
    @State private var storefrontGameIndex = 0
    @State private var storefrontGameAction = 0
    @State private var storefrontFocusZone = 0
    @State private var storefrontActionIndex = 0
    @State private var storeSignInURL: URL?
    @State private var signInProvider: WindowsStorefront = .epic
    @State private var storeAppFocusZone = 0
    @State private var storeAppActionIndex = 0
    @State private var storeAppGameIndex = 0
    @State private var storeAppShowingLibrary = false
    private var selectedStoreBrowserSession: InAppBrowserSession {
        storefrontRuntime.selectedProvider == .epic ? epicStoreBrowserSession : gogStoreBrowserSession
    }
    @State private var searchOpen = false
    @State private var showingNotificationCenter = false
    @ObservedObject private var notificationCenter = MetalOSNotificationCenter.shared
    @State private var showControllerStatus = false
    @State private var controlCenterOpen = false
    @State private var controlCenterIndex = 0
    @State private var consoleHomeTab: ConsoleHomeTab = .games
    @State private var consoleHomeGames: [ConsoleHomeGame] = []
    @StateObject private var consoleMaintenance = ConsoleMaintenance()
    @State private var help = false
    @State private var browseInstallation: String?
    @State private var contextGameID: String?
    @State private var pendingRemoval: Game?
    @State private var pendingStoreUninstall: (game: WindowsStoreGame, provider: WindowsStorefront)?
    @State private var contextIndex = 0
    @State private var homeRow = 1
    @State private var topIndex = 0
    @State private var actionIndex = 0
    @State private var welcomeCardIndex = 0
    @State private var gameScreenshotIndex = 0
    @State private var selectedGameScreenshot: ArtworkRecord?
    @State private var detailsGameID: String?
    @State private var preparedBottleExecutableGameID: String?
    @State private var detailsActionIndex = 0
    @State private var detailsScrollTarget = 0
    @State private var welcomeCaptures: [URL] = []
    @State private var storageAvailableText = "Checking…"
    @State private var storageTotalText = ""
    @State private var storageUsedFraction: Double?
    @State private var welcomeSelected = true
    @State private var addCardSelected = false
    @State private var selectedStoreTile: Int?
    @State private var profileToastAction = 0
    @State private var dismissedProfileToastKey: String?
    @FocusState private var libraryFocused: Bool
    private let columns = 5
    private var navigationActive: Bool {
        controller.activeInputScopeID == nil && detailsGameID == nil && !(storeAppPage && !storeAppShowingLibrary) && contextGameID == nil && browseInstallation == nil && !help && !controlCenterOpen && !showingNotificationCenter && !store.showSettings && !store.showGameImport && !store.showImport && !store.showBuild && !searchOpen && !showControllerStatus && !settingsShowTester && store.notice == nil
    }
    private var welcomeGames: [Game] { store.data.games.filter(\.isGame) }
    private var storefrontGames: [WindowsStoreGame] {
        storefrontRuntime.selectedProvider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames
    }
    private enum PlatformApp: String, CaseIterable, Identifiable {
        case epic = "Epic Games"
        case gog = "GOG"
        case switchApp = "Switch"
        case windowsEXE = "Windows EXE"
        var id: String { rawValue }
    }
    private var installedPlatformApps: [PlatformApp] {
        var apps: [PlatformApp] = []
        guard let workspace = store.workspaceURL else { return apps }
        if FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.legendaryCLI(in: workspace).path) { apps.append(.epic) }
        if FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.gogdlCLI(in: workspace).path) { apps.append(.gog) }
        if NXBuildEnvironment.isCheckout(store.data.settings.forkPath) || NXBuildEnvironment.isCheckout(workspace.appendingPathComponent(".nxstudio/Engines/NXNative-Yubismartlabs").path) { apps.append(.switchApp) }
        if store.data.games.contains(where: { $0.source == .windows }) { apps.append(.windowsEXE) }
        return apps
    }
    private var recentWelcomeGame: Game? {
        welcomeGames.filter { $0.lastPlayed != nil }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }
    private var favoriteWelcomeGame: Game? {
        welcomeGames.filter(\.favorite).sorted {
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.first
    }
    private var profileUpdateGame: Game? {
        store.data.games.first { game in
            game.source == .nxnative && game.builtNXProfileRevision != nil &&
            game.nxSupport?.latestProfileRevision != nil &&
            game.builtNXProfileRevision != game.nxSupport?.latestProfileRevision &&
            profileToastKey(for: game) != dismissedProfileToastKey
        }
    }
    var body: some View {
        GeometryReader { geometry in
            if !store.setupComplete {
                FirstRunSetupView().environmentObject(store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else if store.showSettings && !store.console {
                SettingsView(isPage: true, onClose: { store.showSettings = false }).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else if store.showGameImport {
                AddGameView(
                    onSwitch: { launchWindowsInstallerFlow = false; store.showGameImport = false; store.showImport = true },
                    onClose: { store.showGameImport = false; launchWindowsInstallerFlow = false },
                    startWithWindowsInstaller: launchWindowsInstallerFlow
                ).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else if store.showImport {
                SwitchImportView(onClose: { store.showImport = false }).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else if let id = preparedBottleExecutableGameID,
                      let game = store.data.games.first(where: { $0.id == id }) {
                PreparedLutrisExecutablePage(game: game) { executable in
                    preparedBottleExecutableGameID = nil
                    _ = store.attachWindowsGame(at: executable, toPreparedBottle: id)
                }
                .environment(\.consolePageClose, { preparedBottleExecutableGameID = nil })
                .transition(.opacity)
            } else if store.console, let id = detailsGameID,
                      let game = store.data.games.first(where: { $0.id == id }) {
                ConsoleGameDetail(game: game, onClose: { detailsGameID = nil }, onAction: handleGameDetailAction)
                    .id(id)
                    .transition(.opacity)
            } else if let detailsGameID {
                GameDetailsView(gameID: detailsGameID, selectedAction: $detailsActionIndex,
                                scrollTarget: $detailsScrollTarget,
                                onClose: { self.detailsGameID = nil },
                                onAction: handleGameDetailAction)
                    .environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            } else if store.showBuild {
                BuildView(gameID: store.selected?.id, onClose: { store.showBuild = false }).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else if store.console && consoleHomeTab != .games {
                ConsoleSystemPage(maintenance: consoleMaintenance, tab: $consoleHomeTab)
            } else if store.console {
                ConsoleHomeHub(
                    games: consoleHomeGames,
                    wallpaperPaths: consoleWallpaperPaths,
                    wallpaperVideo: consoleWallpaperVideo,
                    accent: appearance.accent,
                    tab: $consoleHomeTab,
                    selectedID: $store.selectedID,
                    onAction: performConsoleHomeAction
                ) {
                    ConsoleLiveHomeStatus()
                }
            } else {
            ZStack {
                HomeBackdrop(game: selectedStoreTile != nil || welcomeSelected ? nil : store.selected,
                             wallpaperPath: store.data.settings.homeWallpaperPath)
                    .ignoresSafeArea()
                HomeParticleField(enabled: store.data.settings.homeParticlesEnabled ?? true)
                VStack(alignment: .leading, spacing: 0) {
                    navigationBar
                    if browserPage {
                        InAppBrowserView(session: browserSession, close: { selectPage(apps: false) })
                            .padding(.top, 12).padding(.bottom, 8)
                    } else if libraryPage {
                        storefrontLibraryView.padding(.top, 18)
                    } else if storeAppPage {
                        storefrontAppView.padding(.top, 18)
                    } else if appsPage {
                        appsView.padding(.top, 18)
                    } else {
                        gameRail.padding(.top, 26)
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 20) {
                                if store.selected != nil && !welcomeSelected && selectedStoreTile == nil {
                                    spotlight(compact: geometry.size.height < 780)
                                    .frame(minHeight: max(geometry.size.height * 0.56, 500), alignment: .topLeading)
                                    gameMetadataPanel
                                        .frame(minHeight: 180, maxHeight: 250, alignment: .topLeading)
                                        .id("game-details")
                                } else {
                                    welcomeDashboard(compact: geometry.size.height < 780)
                                        .frame(minHeight: max(geometry.size.height * 0.48, 420), alignment: .topLeading)
                                }
                            }.padding(.bottom, 24)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: homeRow) { _, row in
                            if row >= 3 { withAnimation(.easeInOut(duration: 0.24)) { scrollProxy.scrollTo("game-details", anchor: .center) } }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    }
                    if !browserPage { footer }
            }.padding(.horizontal, store.console ? 66 : 52).padding(.top, 46)
            }
            }
        }
        .consoleMotion()
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                if store.isImportingGame {
                    HStack(spacing: 13) {
                        ProgressView().tint(studioAccent).controlSize(.small)
                        Text(store.gameImportStatus).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13).frame(width: 470)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let toast = notificationCenter.toastRecord {
                    NotificationToastView(record: toast, openCenter: {
                        showingNotificationCenter = true
                        notificationCenter.dismissToast(toast.id)
                    }, dismiss: { notificationCenter.dismissToast(toast.id) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if store.builder.isBuilding {
                    BuildProgressToast(builder: store.builder,
                                       gameTitle: store.data.games.first(where: { $0.id == store.builder.currentGameID })?.title ?? "Game",
                                       showBuild: { store.showBuild = true })
                }
                if !store.console, let updated = profileUpdateGame {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(studioAccent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NXNATIVE PROFILE UPDATED").font(.system(size: 11, weight: .bold)).tracking(1.1).foregroundStyle(studioAccent)
                            Text("\(updated.title) has new fixes. Rebuild to apply them.").font(.system(size: 12))
                        }
                        Spacer()
                        Button("Update / Rebuild") { openProfileUpdate(updated) }
                            .buttonStyle(.borderedProminent).tint(studioAccent).foregroundStyle(studioBackground)
                            .consoleFocus(profileToastAction == 0, cornerRadius: 8, scale: 1.04)
                        Button("Later") { dismissProfileUpdate(updated) }
                            .buttonStyle(.bordered).consoleFocus(profileToastAction == 1, cornerRadius: 8, scale: 1.04)
                    }
                    .padding(14).frame(width: 650)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(studioAccent.opacity(0.3)))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                }
                if let message = store.builder.toastMessage {
                HStack(spacing: 10) {
                    Image(systemName: store.builder.isBuilding ? "hammer.fill" : store.builder.status == "Build complete" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(studioAccent)
                    Text(message).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Button { store.builder.dismissToast() } label: { Image(systemName: "xmark").font(.caption.bold()) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).padding(.leading, 5)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .padding(.top, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.builder.toastMessage == message { store.builder.dismissToast() }
                }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let notification = storefrontRuntime.notification {
                StorefrontNotificationToast(notification: notification, runtime: storefrontRuntime)
                    .padding(.top, 14).padding(.trailing, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notification.id) {
                        guard !notification.isActive else { return }
                        try? await Task.sleep(for: .seconds(6))
                        storefrontRuntime.dismissNotification(notification.id)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.builder.toastMessage)
        .animation(feedback.pageAnimation, value: store.showSettings)
        .animation(feedback.pageAnimation, value: store.showBuild)
        .animation(feedback.pageAnimation, value: detailsGameID)
        .animation(feedback.pageAnimation, value: appsPage)
        .animation(feedback.pageAnimation, value: libraryPage)
        .onChange(of: store.visibleGames.count) { _, count in
            if !appsPage && !libraryPage && !storeAppPage { welcomeSelected = count == 0; addCardSelected = false }
        }
        .onChange(of: store.showingApps) { _, value in
            if value {
                appsPage = true
                libraryPage = false
                storeAppPage = false
                browserPage = false
                topIndex = 1
            } else if appsPage {
                appsPage = false
                libraryPage = false
                storeAppPage = false
                browserPage = false
                topIndex = 0
            }
        }
        .consoleOverlayBackdrop(contextGameID != nil || store.notice != nil)
        .overlay { contextOverlay.animation(feedback.pageAnimation, value: contextGameID).animation(feedback.focusAnimation, value: contextIndex) }
        .overlay { controlCenterOverlay.animation(feedback.pageAnimation, value: controlCenterOpen).animation(feedback.focusAnimation, value: controlCenterIndex) }
        .overlay {
            if showingNotificationCenter {
                NotificationCenterPanel { showingNotificationCenter = false }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(studioBackground.ignoresSafeArea())
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(120)
            }
        }
        .background {
            LibraryKeyHandler(enabled: (navigationActive || (detailsGameID != nil && !store.console)) && !browserPage) { command in
                navigate(command)
            }
        }
        .background(studioBackground.ignoresSafeArea()).tint(studioAccent)
        .consolePage(isPresented: Binding(get: { browseInstallation != nil }, set: { if !$0 { browseInstallation = nil } })) {
            ConsoleFilePicker(title: "Game installation", mode: .file, startingPath: browseInstallation) { _ in browseInstallation = nil }
        }
        .consolePage(isPresented: $searchOpen, onDismiss: { libraryFocused = true }) {
            SearchKeyboardView(query: $store.query) { searchOpen = false }
        }
        .consolePage(isPresented: Binding(get: { storeSignInURL != nil }, set: { if !$0 { storeSignInURL = nil } })) {
            if let url = storeSignInURL {
                StoreSignInBrowser(title: "Sign in to \(signInProvider.rawValue)", url: url,
                                   session: signInProvider == .epic ? epicStoreBrowserSession : gogStoreBrowserSession) { code in
                    let provider = signInProvider
                    Task {
                        if provider == .epic { await storefrontRuntime.completeEpicLogin(code: code, workspace: store.workspaceURL) }
                        else { await storefrontRuntime.completeGOGLogin(code: code, workspace: store.workspaceURL) }
                        await store.scan()
                        store.mergeOwnedStoreGames(storefrontRuntime.selectedProvider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames,
                                                   provider: storefrontRuntime.selectedProvider)
                        if storeAppPage {
                            let address = provider == .epic ? "https://store.epicgames.com/en-US/" : "https://www.gog.com/"
                            (provider == .epic ? epicStoreBrowserSession : gogStoreBrowserSession).loadAddress(address)
                        }
                    }
                }
            }
        }
        .consolePage(isPresented: $showControllerStatus, onDismiss: { if !store.console { libraryFocused = true } }) {
            ControllerStatusView()
        }
        .consolePage(isPresented: Binding(get: { settingsShowTester }, set: { settingsShowTester = $0 })) {
            GamepadTesterView()
        }
        .consolePage(isPresented: $help) {
            HelpView()
        }
        .consolePage(isPresented: Binding(get: { selectedGameScreenshot != nil }, set: { if !$0 { selectedGameScreenshot = nil } })) {
            gameScreenshotPreview
        }
        .consolePage(isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            if let game = pendingRemoval {
                ActionConfirmationView(title: "Remove \(game.title)?", message: "This removes the game from your MetalOS library. Its app or game files will stay where they are.", confirmTitle: "Remove from library", destructive: true) {
                    store.removeGame(id: game.id)
                    pendingRemoval = nil
                }
            }
        }
        .consolePage(isPresented: Binding(get: { pendingStoreUninstall != nil }, set: { if !$0 { pendingStoreUninstall = nil } })) {
            if let pendingStoreUninstall {
                ActionConfirmationView(title: "Uninstall \(pendingStoreUninstall.game.title)?",
                                       message: "This removes the installed game files. Your store ownership, MetalOS compatibility settings, and local saves are kept.",
                                       confirmTitle: "Uninstall game", destructive: true) {
                    let request = pendingStoreUninstall
                    Task {
                        await storefrontRuntime.uninstall(request.game, provider: request.provider, workspace: store.workspaceURL)
                        mergeOwnedStoreGames(for: request.provider)
                        await store.scan()
                        self.pendingStoreUninstall = nil
                    }
                }
            }
        }
        .consolePage(isPresented: Binding(get: { pendingPlatformInstall != nil }, set: { if !$0 { pendingPlatformInstall = nil } })) {
            if let app = pendingPlatformInstall {
                let details = platformAppCopy(app).2
                ActionConfirmationView(title: "Install \(app.rawValue)?",
                                       message: "MetalOS will prepare \(app.rawValue) for use. \(details)",
                                       confirmTitle: "Install app") {
                    pendingPlatformInstall = nil
                    installPlatformApp(app)
                }
            }
        }
        .consolePage(isPresented: $showSwitchRequirementsConfirmation) {
            ActionConfirmationView(title: "Install Switch requirements?",
                                   message: "MetalOS will install the available build tools and Python packages needed by NXNative. Some Apple developer tools may require manual setup.",
                                   confirmTitle: "Install requirements") {
                Task {
                    await switchAppInstaller.installConfirmedRequirements()
                    persistSwitchRuntime()
                }
            }
        }
        .consolePage(isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            FullPageMessage(title: "MetalOS", message: store.notice ?? "", symbol: "exclamationmark.triangle", buttonTitle: "Continue")
        }
        .onKeyPress(.leftArrow) { handleNavigationKey("left") }
        .onKeyPress(.rightArrow) { handleNavigationKey("right") }
        .onKeyPress(.upArrow) { handleNavigationKey("up") }
        .onKeyPress(.downArrow) { handleNavigationKey("down") }
        .onKeyPress(.return) { handleNavigationKey("confirm") }
        .onKeyPress(.escape) { handleNavigationKey("back") }
        .onKeyPress(.space) { handleNavigationKey("context") }
        .onKeyPress("m") { handleNavigationKey("context") }
        .onKeyPress("p") { handleNavigationKey("home") }
        .focusable().focused($libraryFocused).focusEffectDisabled()
        .onChange(of: store.showSettings) { _, open in
            if open && store.console {
                detailsGameID = nil
                consoleHomeTab = .settings
                store.showSettings = false
            } else if !open && !store.console {
                libraryFocused = true
            }
        }
        .onChange(of: store.showImport) { _, open in if !open && !store.console { libraryFocused = true } }
        .onChange(of: store.showBuild) { _, open in if !open && !store.console { libraryFocused = true } }
        .onChange(of: store.console) { _, enabled in
            if enabled { refreshConsoleGames() }
            else { libraryFocused = true }
            applyConsolePresentation(enabled)
        }
        .onChange(of: store.data.games, initial: true) { _, _ in
            if store.console { refreshConsoleGames() }
        }
        .onChange(of: store.data.settings.defaultWindowsRuntime) { _, _ in
            if store.console { refreshConsoleGames() }
        }
        .task(id: store.setupComplete) {
            guard store.setupComplete else { return }
            if !store.console { libraryFocused = true }
            controller.action = navigate
            controller.homeAction = { withAnimation(feedback.pageAnimation) { controlCenterOpen.toggle() } }
            controller.priorityAction = { command in
                if store.notice != nil {
                    if ["confirm", "back", "menu", "context"].contains(command) { store.notice = nil }
                    return true
                }
                return handleProfileUpdateToast(command)
            }
            if store.console {
                applyConsolePresentation(true)
            }
            store.prepareArtwork()
            await store.scan()
            refreshWelcomeStats()
        }
        .onChange(of: store.workspacePath) { _, _ in refreshWelcomeStats() }
        .onChange(of: profileUpdateGame?.id) { _, gameID in
            guard let gameID, let game = store.data.games.first(where: { $0.id == gameID }) else { return }
            notificationCenter.post("NXNative profile updated", "New fixes are available for \(game.title). Rebuild it to apply them.", category: .builds, level: .warning)
        }
        .onChange(of: storefrontRuntime.notification?.id) { _, _ in
            guard let notification = storefrontRuntime.notification else { return }
            let level: AppNotificationLevel = notification.title.localizedCaseInsensitiveContains("fail") ? .error : notification.title.localizedCaseInsensitiveContains("complete") ? .success : .info
            notificationCenter.post(notification.title, notification.message, category: .library, level: level)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshWelcomeStats()
                if store.console { refreshConsoleGames() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if store.console, let window = note.object as? NSWindow, window === libraryWindow {
                store.console = false
            }
        }
        .onDisappear { controller.action = nil; controller.priorityAction = nil; controller.homeAction = nil }
    }
    @State private var settingsShowTester = false

    private var libraryWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain && $0.sheetParent == nil && $0.isMainWindow }
            ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain && $0.sheetParent == nil }
    }

    private func applyConsolePresentation(_ enabled: Bool) {
        NSApp.presentationOptions = enabled ? [.hideDock, .hideMenuBar] : []
        guard let window = libraryWindow else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if window.styleMask.contains(.fullScreen) != enabled { window.toggleFullScreen(nil) }
    }

    private var consoleWallpaperPaths: [String] {
        let stored = store.data.settings.homeWallpaperPath
        if let preset = WallpaperPreset.fromStorageValue(stored), let path = preset.imageURL?.path { return [path] }
        return [consoleWallpaperVideo == nil ? stored : nil, WallpaperPreset.blueHorizon.imageURL?.path].compactMap { $0 }
    }

    private var consoleWallpaperVideo: URL? {
        guard let path = store.data.settings.homeWallpaperPath else { return nil }
        let url = URL(fileURLWithPath: path)
        return ["mov", "mp4", "m4v", "qt"].contains(url.pathExtension.lowercased()) ? url : nil
    }

    private func refreshConsoleGames() {
        consoleHomeGames = store.consoleGames.map {
            ConsoleHomeGame($0, windowsDefault: store.data.settings.defaultWindowsRuntime)
        }
    }

    private func performConsoleHomeAction(_ action: ConsoleHomeAction) {
        switch action {
        case .play(let id):
            if let game = store.data.games.first(where: { $0.id == id }) {
                store.selectedID = id
                store.launch(game)
            }
        case .gameHub(let id):
            if let game = store.data.games.first(where: { $0.id == id }) { openGameDetails(game) }
        case .addGame:
            store.showGameImport = true
        case .openTab(let tab):
            if tab == .games { store.showGameImport = true }
            else { consoleHomeTab = tab }
        case .accessories:
            showControllerStatus = true
        case .exitConsole:
            store.toggleConsole()
        case .guide:
            GameOverlayController.shared.toggle()
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 24) {
            Text("METALOS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.1).foregroundStyle(.white.opacity(0.62))
                .padding(.trailing, 8)
            pageTab("Games", selected: !appsPage && !storeAppPage && !browserPage, slot: 0) { selectPage(apps: false) }
            pageTab("Apps", selected: appsPage, slot: 1) { selectPage(apps: true) }
            Spacer(minLength: 16)
            toolbarButton("magnifyingglass", "Search games", slot: 2) { searchOpen = true }
                .keyboardShortcut("f", modifiers: .command)
            toolbarButton("gearshape", "Settings", slot: 3) { store.showSettings = true }
            toolbarButton("bell", "Notifications", slot: 4, badge: notificationCenter.unreadCount) { showingNotificationCenter = true }
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 34, height: 34)
                .help("User profile · Coming soon")
                .accessibilityLabel("User profile, coming soon")
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Text(timeline.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .regular, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85)).frame(minWidth: 54, alignment: .trailing)
            }
        }.frame(height: 38)
    }
    private func pageTab(_ title: String, selected: Bool, slot: Int, action: @escaping () -> Void) -> some View {
        Button {
            action(); homeRow = 0; topIndex = slot; libraryFocused = true
        } label: {
            VStack(spacing: 11) {
                Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.52))
            }.fixedSize(horizontal: true, vertical: false).frame(height: 38, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 0 && topIndex == slot, cornerRadius: 5, scale: 1.035)
    }
    private func toolbarButton(_ symbol: String, _ label: String, slot: Int, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 32, height: 34)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                            .background(Color(red: 0.85, green: 0.22, blue: 0.30), in: Capsule())
                            .offset(x: 5, y: -3)
                    }
                }
        }
            .buttonStyle(ConsoleButtonStyle()).foregroundStyle(homeRow == 0 && topIndex == slot ? .white : .white.opacity(0.66)).consoleFocus(navigationActive && homeRow == 0 && topIndex == slot, cornerRadius: 9, scale: 1.13).help(label).accessibilityLabel(label)
    }
    private var gameRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    StoreHomeTile(selected: selectedStoreTile == 0,
                                  focused: navigationActive && homeRow == 1 && selectedStoreTile == 0) {
                        selectedStoreTile = 0; welcomeSelected = false; addCardSelected = false
                        store.selectedID = nil; homeRow = 1; libraryFocused = true
                    }.id("store-home")
                    WelcomeTile(selected: welcomeSelected, focused: navigationActive && homeRow == 1 && welcomeSelected) {
                        welcomeSelected = true; addCardSelected = false; selectedStoreTile = nil; store.selectedID = nil; homeRow = 1; libraryFocused = true
                    }
                    ForEach(store.visibleGames) { game in
                        let installingStoreGame = storefrontRuntime.isInstallingGame
                            && storefrontRuntime.installGameID == game.windowsStoreGameID
                            && storefrontRuntime.installProvider?.rawValue.lowercased().contains(game.windowsStoreProvider ?? "") == true
                        HomeTile(game: game, selected: selectedStoreTile == nil && !welcomeSelected && !addCardSelected && store.selected?.id == game.id,
                                 focused: navigationActive && homeRow == 1 && selectedStoreTile == nil && !welcomeSelected && !addCardSelected && store.selected?.id == game.id,
                                 building: store.builder.isBuilding && store.builder.currentGameID == game.id,
                                 progress: store.builder.progress,
                                 installing: installingStoreGame,
                                 installationProgress: installingStoreGame ? storefrontRuntime.installProgress : nil) {
                            welcomeSelected = false; addCardSelected = false; selectedStoreTile = nil; homeRow = 1; store.selectedID = game.id; libraryFocused = true
                        }.id(game.id).contextMenu { gameMenu(game) }
                    }
                    AddGameTile(selected: addCardSelected, focused: navigationActive && homeRow == 1 && addCardSelected) {
                        addCardSelected = true; welcomeSelected = false; selectedStoreTile = nil; homeRow = 1; libraryFocused = true; store.importApp()
                    }
                }.padding(6)
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.23)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: selectedStoreTile) { _, index in
                guard index != nil else { return }
                withAnimation(.easeInOut(duration: 0.23)) { proxy.scrollTo("store-home", anchor: .center) }
            }
        }.frame(height: 190)
    }
    private func spotlight(compact: Bool) -> some View {
        Group {
            if let game = store.selected {
                let storeProvider: WindowsStorefront? = game.windowsStoreProvider == "epic" ? .epic : game.windowsStoreProvider == "gog" ? .gog : nil
                let storeGame = game.windowsStoreGameID.map { WindowsStoreGame(id: $0, title: game.title, installedPath: game.isAvailable ? game.installPath : nil) }
                let installingStoreGame = storeProvider != nil && storefrontRuntime.isInstallingGame
                    && storefrontRuntime.installGameID == game.windowsStoreGameID
                    && storefrontRuntime.installProvider == storeProvider
                VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                    HStack(spacing: 9) {
                        Image(systemName: game.source.symbol)
                        Text(game.source.rawValue.uppercased()).tracking(3)
                        if game.favorite { Image(systemName: "heart.fill").foregroundStyle(studioAccent) }
                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Text(game.title).font(.system(size: compact ? 46 : 66, weight: .light)).tracking(-2)
                        .lineLimit(2).frame(maxWidth: 700, alignment: .leading).id(game.id)
                    Text(installingStoreGame ? storefrontRuntime.installProgressLabel : game.metadata?.summary ?? (game.isAvailable ? (game.launchURL.isEmpty ? "Play starts the first build automatically." : "Your next session is ready.") : storeProvider != nil ? "Ready to install from \(storeProvider!.rawValue)." : "Reconnect this game's drive to play."))
                        .font(.system(size: 17, weight: .light)).foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3).frame(maxWidth: 680, alignment: .leading)
                    Spacer(minLength: compact ? 140 : 280)
                    if store.builder.isBuilding && store.builder.currentGameID == game.id {
                        HStack(spacing: 12) {
                            Group {
                                if let progress = store.builder.progress { ProgressView(value: progress).tint(studioAccent) }
                                else { ProgressView().tint(studioAccent) }
                            }.frame(maxWidth: 260)
                            Text(store.builder.progress.map { "BUILDING · \(Int($0 * 100))%" } ?? "BUILDING")
                                .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(studioAccent)
                            Text(store.builder.activePhase).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }.frame(maxWidth: 650, alignment: .leading).accessibilityElement(children: .combine)
                    }
                    HStack(spacing: 14) {
                        Button {
                            if installingStoreGame {
                                storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall()
                            } else if !game.isAvailable, let storeGame, let storeProvider {
                                Task {
                                    await storefrontRuntime.install(storeGame, provider: storeProvider, workspace: store.workspaceURL)
                                    mergeOwnedStoreGames(for: storeProvider)
                                    await store.scan()
                                }
                            } else {
                                store.launch(game)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: installingStoreGame ? (storefrontRuntime.isInstallPaused ? "play.fill" : "pause.fill") : game.isAvailable ? "play.fill" : "arrow.down.to.line").font(.system(size: 12))
                                Text(installingStoreGame ? (storefrontRuntime.isInstallPaused ? "Resume install" : "Pause install") : game.isAvailable ? "Play Game" : storeProvider != nil ? "Install Game" : "Play Game").font(.system(size: 15, weight: .semibold))
                            }.foregroundStyle(.black).frame(width: 205, height: 48).background(.white, in: Capsule())
                        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 0, cornerRadius: 24, scale: 1.045).disabled(storeProvider == nil && !game.isAvailable)
                        if installingStoreGame {
                            Button { storefrontRuntime.cancelInstall() } label: {
                                Image(systemName: "stop.fill").font(.system(size: 13)).frame(width: 48, height: 48).background(.white.opacity(0.09), in: Circle())
                            }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 1, cornerRadius: 24, scale: 1.045).help("Stop installation").accessibilityLabel("Stop installation")
                        } else {
                            Button { openContext(for: game) } label: {
                                Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 56, height: 48).background(.black.opacity(0.30), in: Capsule())
                            }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 1, cornerRadius: 24, scale: 1.045).help("Game options · Menu / Options").accessibilityLabel("Game options")
                        }
                        Text(game.isAvailable ? (game.launchURL.isEmpty ? "NOT BUILT" : "BUILT") : "OFFLINE")
                            .font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.35)).padding(.leading, 6)
                    }.padding(.top, 5)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 10)
                    .transition(.opacity).animation(.easeOut(duration: 0.25), value: game.id)
            }
        }
    }
    private var gameMetadataPanel: some View {
        Group {
            if let game = store.selected {
                let metadata = game.metadata
                let screenshots = metadata?.screenshots ?? []
                let description = [metadata?.summary, metadata?.storyline]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("ABOUT THIS GAME").font(.system(size: 9, weight: .bold)).tracking(1.7).foregroundStyle(studioAccent)
                            if let date = metadata?.releaseDate { Text(date).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)) }
                            Spacer()
                            if let raw = metadata?.sourceURL, let url = URL(string: raw) { Link("Source ↗", destination: url).font(.system(size: 10)) }
                        }
                        if description.isEmpty {
                            Text(store.isFetchingArtwork ? "Finding the full game description…" : "A full description and screenshots will appear here when available.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.52))
                        } else {
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(description).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        let facts = [metadata?.genres.joined(separator: " · "), metadata?.platforms.joined(separator: " · "), metadata?.developers.joined(separator: " · ")]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        if !facts.isEmpty { Text(facts.joined(separator: "   •   ")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.46)).lineLimit(1) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if !screenshots.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("SCREENSHOTS").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.58))
                                Spacer()
                                Text("A to view").font(.system(size: 9)).foregroundStyle(.white.opacity(0.38))
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 11) {
                                    ForEach(Array(screenshots.enumerated()), id: \.element.path) { index, shot in
                                        if let image = NSImage(contentsOfFile: shot.path) {
                                            Button {
                                                gameScreenshotIndex = index
                                                selectedGameScreenshot = shot
                                            } label: {
                                                Image(nsImage: image).resizable().scaledToFill()
                                                    .frame(width: 184, height: 112).clipped()
                                                    .overlay(alignment: .bottomTrailing) {
                                                        Text(String(format: "%02d", index + 1)).font(.system(size: 9, weight: .bold)).padding(5)
                                                            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5)).padding(6)
                                                    }
                                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12)))
                                            }.buttonStyle(ConsoleButtonStyle())
                                                .consoleFocus(navigationActive && homeRow == 3 && gameScreenshotIndex == index, cornerRadius: 9, scale: 1.035)
                                        }
                                    }
                                }
                            }
                        }.frame(width: 410, alignment: .leading)
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            }
        }
    }

    private var gameScreenshotPreview: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selected?.title ?? "Game screenshot").font(.system(size: 16, weight: .semibold))
                    Text("GAME SCREENSHOT").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(studioAccent)
                }
                Spacer()
                Button("Close") { selectedGameScreenshot = nil }.buttonStyle(.bordered)
            }
            if let screenshot = selectedGameScreenshot, let image = NSImage(contentsOfFile: screenshot.path) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1100, maxHeight: 680)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("B / Esc  Back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 1180, height: 780).background(studioBackground).preferredColorScheme(.dark)
            .consoleInput { command in if ["back", "menu", "context"].contains(command) { selectedGameScreenshot = nil } }
    }

    private var gameScreenshotSelectionCount: Int { store.selected?.metadata?.screenshots.count ?? 0 }

    private func welcomeDashboard(compact: Bool) -> some View {
        let rowHeight: CGFloat = compact ? 108 : 132
        let connected = controller.devices
        let captureCount = welcomeCaptures.count
        let gameCount = welcomeGames.count
        let appCount = installedPlatformApps.count
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GAMES").font(.system(size: 9, weight: .bold)).tracking(2.1).foregroundStyle(studioAccent)
                    Text("Welcome back").font(.system(size: compact ? 22 : 27, weight: .light)).tracking(-0.5)
                }
                Spacer()
                Text("\(gameCount) GAMES  ·  \(appCount) APPS")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 9) {
                Button { selectLibraryPage() } label: { Label("Explore the Store", systemImage: "bag.fill") }
                    .buttonStyle(.borderedProminent).tint(studioAccent)
                    .consoleFocus(navigationActive && homeRow == 2 && actionIndex == 0, cornerRadius: 8, scale: 1.04)
                Button { store.importApp() } label: { Label("Add a game", systemImage: "plus") }
                    .buttonStyle(.bordered).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 1, cornerRadius: 8, scale: 1.04)
                Spacer()
                Text("QUICK ACCESS").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.36))
            }
            HStack(spacing: 12) {
                welcomeBentoCard(index: 0, eyebrow: "PICK UP WHERE YOU LEFT OFF",
                                 title: recentWelcomeGame?.title ?? "No recent games yet",
                                 detail: recentWelcomeGame?.lastPlayed?.formatted(.relative(presentation: .named)) ?? "Your recent games will appear here",
                                 symbol: "play.fill", value: recentWelcomeGame == nil ? "—" : "PLAY", artwork: recentWelcomeGame?.boxArt?.path,
                                 accent: Color(red: 0.08, green: 0.32, blue: 0.76), height: rowHeight) { performWelcomeCard(0) }
                welcomeBentoCard(index: 1, eyebrow: "CONNECTED DEVICES",
                                 title: connected.first?.name ?? "No controller connected",
                                 detail: connected.isEmpty ? "Connect a gamepad to play from the couch" : connected.map { "\($0.name) · \($0.batteryText)" }.joined(separator: "\n"),
                                 symbol: "gamecontroller.fill", value: connected.isEmpty ? "0" : "\(connected.count)",
                                 accent: Color(red: 0.05, green: 0.42, blue: 0.55), height: rowHeight) { performWelcomeCard(1) }
                welcomeBentoCard(index: 2, eyebrow: "GAME CAPTURES",
                                 title: captureCount == 1 ? "1 screenshot" : "\(captureCount) screenshots",
                                 detail: captureCount == 0 ? "Your Game Bar captures will show here" : welcomeCaptures.first?.lastPathComponent ?? "Saved in Pictures / MetalOS",
                                 symbol: "camera.fill", value: captureCount == 0 ? "—" : "\(captureCount)",
                                 artwork: welcomeCaptures.first?.path,
                                 accent: Color(red: 0.43, green: 0.23, blue: 0.68), height: rowHeight) { performWelcomeCard(2) }
            }
            HStack(spacing: 12) {
                welcomeBentoCard(index: 3, eyebrow: "LIBRARY STORAGE",
                                 title: storageAvailableText,
                                 detail: storageTotalText.isEmpty ? store.workspacePath : "Available on your game library drive · \(storageTotalText) total",
                                 symbol: "externaldrive.fill", value: "\(gameCount)", progress: storageUsedFraction,
                                 accent: Color(red: 0.04, green: 0.39, blue: 0.48), height: rowHeight) { performWelcomeCard(3) }
                welcomeBentoCard(index: 4, eyebrow: "FAVORITES",
                                 title: favoriteWelcomeGame?.title ?? "Make a game a favorite",
                                 detail: "\(welcomeGames.filter(\.favorite).count) saved games", symbol: "heart.fill",
                                 artwork: favoriteWelcomeGame?.boxArt?.path,
                                 accent: Color(red: 0.56, green: 0.18, blue: 0.34), height: rowHeight) { performWelcomeCard(4) }
                welcomeBentoCard(index: 5, eyebrow: "YOUR COLLECTION",
                                 title: "\(gameCount) games · \(appCount) apps",
                                 detail: store.isScanning ? "Refreshing your collection…" : "Open Apps to launch your installed platforms",
                                 symbol: "square.grid.2x2.fill", value: "VIEW", accent: Color(red: 0.12, green: 0.31, blue: 0.54), height: rowHeight) { performWelcomeCard(5) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { controller.refreshStatus(); refreshWelcomeStats() }
    }

    private func welcomeBentoCard(index: Int, eyebrow: String, title: String, detail: String,
                                  symbol: String, value: String? = nil, artwork: String? = nil,
                                  progress: Double? = nil, accent: Color, height: CGFloat,
                                  action: @escaping () -> Void) -> some View {
        Button {
            welcomeCardIndex = index
            action()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                        Text(eyebrow).font(.system(size: 8, weight: .bold)).tracking(1.2).lineLimit(1)
                        Spacer(minLength: 0)
                        if let value { Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit() }
                    }.foregroundStyle(.white.opacity(0.68))
                    Spacer(minLength: 0)
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                    if let progress { ProgressView(value: progress).tint(studioAccent) }
                }
                if let artwork, let image = NSImage(contentsOfFile: artwork) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 78, height: height - 20)
                        .clipped().clipShape(RoundedRectangle(cornerRadius: 8)).opacity(0.86)
                }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: [accent.opacity(0.14), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(navigationActive && homeRow == 3 && welcomeCardIndex == index ? 0.48 : 0.14), accent.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: accent.opacity(0.08), radius: 16, y: 7)
            .consoleFocus(navigationActive && homeRow == 3 && welcomeCardIndex == index, cornerRadius: 12, scale: 1.025)
        }.buttonStyle(ConsoleButtonStyle())
            .accessibilityLabel("\(eyebrow). \(title). \(detail)")
    }

    private func refreshWelcomeStats() {
        let pictureRoot = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalOS", isDirectory: true)
        welcomeCaptures = ((try? FileManager.default.contentsOfDirectory(at: pictureRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        let location = store.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? location.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 else {
            storageAvailableText = "Unavailable"
            storageTotalText = ""
            storageUsedFraction = nil
            return
        }
        storageAvailableText = "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free"
        storageTotalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        storageUsedFraction = min(1, max(0, Double(total - free) / Double(total)))
    }

    private func performWelcomeCard(_ index: Int) {
        switch index {
        case 0: if let game = recentWelcomeGame { focusWelcomeGame(game) }
        case 1: controller.refreshStatus(); showControllerStatus = true
        case 2:
            let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        case 3: NSWorkspace.shared.open(store.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser)
        case 4: if let game = favoriteWelcomeGame { focusWelcomeGame(game) }
        case 5: selectPage(apps: true)
        default: break
        }
    }

    private func focusWelcomeGame(_ game: Game) {
        store.selectedID = game.id
        welcomeSelected = false
        addCardSelected = false
        homeRow = 1
    }

    private var appsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .lastTextBaseline) {
                Text("Apps").font(.system(size: 32, weight: .light))
                Text("\(installedPlatformApps.count)").font(.system(size: 13)).foregroundStyle(studioAccent)
                Spacer()
                Text("Your installed platforms").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            if installedPlatformApps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No apps installed yet").font(.system(size: 24, weight: .light))
                    Text("Visit the Store to prepare Epic Games, GOG, or Switch for play.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.52))
                    Button("Open Store") { selectLibraryPage() }
                        .buttonStyle(.borderedProminent).tint(studioAccent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 22) {
                    ForEach(Array(installedPlatformApps.enumerated()), id: \.element.id) { index, app in
                        platformAppTile(app, selected: selectedPlatformAppIndex == index,
                                        focused: navigationActive && homeRow == 1 && selectedPlatformAppIndex == index) {
                            selectedPlatformAppIndex = index
                            launchPlatformApp(app)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var storefrontLibraryView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Store").font(.system(size: 32, weight: .light))
                Text("Install a platform app to prepare its game runtime and requirements.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 18) {
                ForEach(Array(PlatformApp.allCases.enumerated()), id: \.element.id) { index, app in
                    storePlatformCard(app, index: index)
                }
            }
            HStack(spacing: 9) {
                if storefrontRuntime.isWorking || switchAppInstaller.isWorking { ProgressView().controlSize(.small).tint(studioAccent) }
                Text(storefrontRuntime.isWorking ? storefrontRuntime.status : switchAppInstaller.isWorking ? switchAppInstaller.status : storefrontRuntime.status)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                Spacer()
                Text("Installing a platform adds it to Apps.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.36))
            }
            Spacer(minLength: 0)
        }
        .task {
            if let workspace = store.workspaceURL {
                await switchAppInstaller.refresh(workspace: workspace, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
            }
        }
    }
    private func storePlatformCard(_ app: PlatformApp, index: Int) -> some View {
        let installed = installedPlatformApps.contains(app)
        let (symbol, subtitle, implementation) = platformAppCopy(app)
        let actionTitle: String = {
            if app == .windowsEXE { return "Choose .exe" }
            return installed ? "Open" : "Install"
        }()
        return Button {
            selectedStoreCatalogIndex = index
            selectStorePlatform(app)
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(studioAccent)
                    Spacer()
                    Text(installed ? "INSTALLED" : app == .windowsEXE ? "WINDOWS" : "AVAILABLE")
                        .font(.system(size: 8, weight: .bold)).tracking(1.1)
                        .foregroundStyle(installed ? studioAccent : .white.opacity(0.42))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.rawValue).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.57)).fixedSize(horizontal: false, vertical: true)
                    Text(implementation).font(.system(size: 10)).foregroundStyle(.white.opacity(0.37)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack {
                    Text(actionTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(studioAccent)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.38))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .background(.white.opacity(selectedStoreCatalogIndex == index ? 0.085 : 0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(studioAccent.opacity(selectedStoreCatalogIndex == index ? 0.36 : 0.12)))
            .consoleFocus(navigationActive && libraryPage && homeRow == 1 && selectedStoreCatalogIndex == index, cornerRadius: 15, scale: 1.025)
        }
        .buttonStyle(ConsoleButtonStyle())
        .disabled((storefrontRuntime.isWorking || switchAppInstaller.isWorking) && app != .windowsEXE)
        .accessibilityLabel("\(actionTitle) \(app.rawValue). \(subtitle) \(implementation)")
    }

    private func platformAppTile(_ app: PlatformApp, selected: Bool, focused: Bool, action: @escaping () -> Void) -> some View {
        let (symbol, subtitle, _) = platformAppCopy(app)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(studioAccent.opacity(0.12))
                    .frame(width: 118, height: 118)
                    .overlay {
                        Image(systemName: symbol).font(.system(size: 36, weight: .regular)).foregroundStyle(studioAccent)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(selected ? 0.32 : 0.1)))
                    .consoleFocus(focused, cornerRadius: 14, scale: 1.045)
                Text(app.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(12)
            .background(.white.opacity(selected ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ConsoleButtonStyle())
        .accessibilityLabel("Open \(app.rawValue). \(subtitle)")
    }

    private func platformAppCopy(_ app: PlatformApp) -> (String, String, String) {
        switch app {
        case .epic: ("e.square.fill", "Open Epic Games and manage your owned games.", "Installs Legendary and its verified Mac runtime files.")
        case .gog: ("g.square.fill", "Open GOG and manage your owned games.", "Installs gogdl and its isolated Python requirements.")
        case .switchApp: ("gamecontroller.fill", "Choose Switch game files and prepare a Mac build.", "Installs NXNative and available build requirements.")
        case .windowsEXE: ("pc", "Choose a Windows setup file and install it in a bottle.", "Creates a clean Windows prefix for each installer.")
        }
    }

    private func selectStorePlatform(_ app: PlatformApp) {
        switch app {
        case .epic:
            if installedPlatformApps.contains(.epic) { selectStoreApp(.epic) }
            else { pendingPlatformInstall = .epic }
        case .gog:
            if installedPlatformApps.contains(.gog) { selectStoreApp(.gog) }
            else { pendingPlatformInstall = .gog }
        case .switchApp:
            if installedPlatformApps.contains(.switchApp) { store.showImport = true }
            else { pendingPlatformInstall = .switchApp }
        case .windowsEXE:
            launchWindowsInstallerFlow = true
            store.showGameImport = true
        }
    }

    private func launchPlatformApp(_ app: PlatformApp) {
        switch app {
        case .epic: selectStoreApp(.epic)
        case .gog: selectStoreApp(.gog)
        case .switchApp: store.showImport = true
        case .windowsEXE:
            launchWindowsInstallerFlow = true
            store.showGameImport = true
        }
    }

    private func installPlatformApp(_ app: PlatformApp) {
        switch app {
        case .epic:
            Task { await storefrontRuntime.installLegendary(workspace: store.workspaceURL) }
        case .gog:
            Task { await storefrontRuntime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
        case .switchApp:
            Task {
                await switchAppInstaller.install(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
                if switchAppInstaller.confirmRequirements {
                    showSwitchRequirementsConfirmation = true
                } else {
                    persistSwitchRuntime()
                }
            }
        case .windowsEXE:
            launchWindowsInstallerFlow = true
            store.showGameImport = true
        }
    }

    private func persistSwitchRuntime() {
        if let checkout = switchAppInstaller.installedCheckout { store.data.settings.forkPath = checkout }
        if let python = switchAppInstaller.installedPython { store.data.settings.pythonPath = python }
        store.save()
    }

    private var storefrontAppView: some View {
        let provider = storefrontRuntime.selectedProvider
        let games = provider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames
        let connected = storefrontRuntime.isConnected(to: provider)
        let toolInstalled = storefrontRuntime.toolInstalled(for: provider)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(provider == .epic ? .white.opacity(0.11) : Color(red: 0.12, green: 0.29, blue: 0.72).opacity(0.44))
                    Image(systemName: provider == .epic ? "e.square.fill" : "g.square.fill")
                        .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider == .epic ? "EPIC GAMES STORE" : "GOG STORE")
                        .font(.system(size: 26, weight: .light)).tracking(1.2)
                    Text(connected ? "Connected with the account used by \(provider == .epic ? "Legendary" : "gogdl")" : "Connect your \(provider.rawValue) account to load owned games")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("METALOS STORE APP").font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(studioAccent)
                    Text("\(games.count) GAMES").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }
            HStack(spacing: 9) {
                if !toolInstalled {
                    Button(provider == .epic ? "Install Legendary" : "Install gogdl") {
                        Task {
                            if provider == .epic { await storefrontRuntime.installLegendary(workspace: store.workspaceURL) }
                            else { await storefrontRuntime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
                        }
                    }.consoleFocus(storeAppShowingLibrary && storeAppFocusZone == 1 && storeAppActionIndex == 0, cornerRadius: 8)
                } else {
                    Button(storefrontRuntime.signInButtonTitle(for: provider)) {
                        storeSignInURL = provider == .epic ? storefrontRuntime.epicLoginURL(workspace: store.workspaceURL) : storefrontRuntime.gogLoginURL()
                        signInProvider = provider
                    }.disabled(!storefrontRuntime.canStartSignIn(for: provider))
                        .consoleFocus(storeAppShowingLibrary && storeAppFocusZone == 1 && storeAppActionIndex == 0, cornerRadius: 8)
                }
                Button("Sync account library") { Task { await refreshStoreApp(provider) } }
                    .disabled(storefrontRuntime.isWorking || !toolInstalled)
                    .consoleFocus(storeAppShowingLibrary && storeAppFocusZone == 1 && storeAppActionIndex == 1, cornerRadius: 8)
                Spacer()
                if storefrontRuntime.isWorking { ProgressView().controlSize(.small).tint(studioAccent) }
                Text(storefrontRuntime.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }.buttonStyle(ConsoleButtonStyle())
            if storefrontRuntime.isInstallingGame, storefrontRuntime.installProvider == provider {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(storefrontRuntime.installProgressLabel).font(.system(size: 11, weight: .medium))
                        if let value = storefrontRuntime.installProgress { ProgressView(value: value).tint(studioAccent) }
                        else { ProgressView().tint(studioAccent) }
                    }
                    Spacer()
                    Button(storefrontRuntime.isInstallPaused ? "Resume" : "Pause") {
                        storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall()
                    }.consoleFocus(storeAppFocusZone == 1 && storeAppActionIndex == 2, cornerRadius: 8)
                    Button("Stop", role: .destructive) { storefrontRuntime.cancelInstall() }
                        .consoleFocus(storeAppFocusZone == 1 && storeAppActionIndex == 3, cornerRadius: 8)
                }.buttonStyle(ConsoleButtonStyle()).padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
            if storeAppShowingLibrary {
            ScrollView {
                if games.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(connected ? "No owned games found" : "Sign in to your \(provider.rawValue) account")
                            .font(.system(size: 20, weight: .light))
                        Text("This native store screen uses the saved \(provider == .epic ? "Legendary" : "gogdl") account. Refresh after claiming or purchasing a game to add it to MetalOS and install it here.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: 640, alignment: .leading)
                    }.frame(maxWidth: .infinity, minHeight: 230, alignment: .leading).padding(.horizontal, 4)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 22) {
                        ForEach(games.indices, id: \.self) { index in
                            let item = games[index]
                            let game = storefrontGame(item, provider: provider)
                            let installing = storefrontRuntime.isInstalling(item, provider: provider)
                            VStack(alignment: .leading, spacing: 9) {
                                GameCard(game: game, selected: storeAppGameIndex == index,
                                         focused: storeAppFocusZone == 2 && storeAppGameIndex == index,
                                         installing: installing,
                                         installationProgress: installing ? storefrontRuntime.installProgress : nil,
                                         select: { storeAppGameIndex = index; storeAppFocusZone = 2 },
                                         launch: { performStoreAppGameAction(item, game: game, provider: provider) })
                                HStack(spacing: 8) {
                                    if installing {
                                        Button(storefrontRuntime.isInstallPaused ? "Resume" : "Pause") {
                                            storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall()
                                        }.consoleFocus(storeAppFocusZone == 2 && storeAppGameIndex == index && storefrontGameAction == 0, cornerRadius: 8)
                                        Button("Stop", role: .destructive) { storefrontRuntime.cancelInstall() }
                                            .consoleFocus(storeAppFocusZone == 2 && storeAppGameIndex == index && storefrontGameAction == 1, cornerRadius: 8)
                                    } else if item.isInstalled {
                                        Button("Play") { store.launch(game) }
                                            .consoleFocus(storeAppFocusZone == 2 && storeAppGameIndex == index && storefrontGameAction == 0, cornerRadius: 8)
                                        Button("Uninstall") { pendingStoreUninstall = (item, provider) }
                                            .consoleFocus(storeAppFocusZone == 2 && storeAppGameIndex == index && storefrontGameAction == 1, cornerRadius: 8)
                                    } else {
                                        Button("Install") { performStoreAppGameAction(item, game: game, provider: provider) }
                                            .consoleFocus(storeAppFocusZone == 2 && storeAppGameIndex == index && storefrontGameAction == 0, cornerRadius: 8)
                                    }
                                }.buttonStyle(ConsoleButtonStyle()).frame(maxWidth: .infinity)
                                    .disabled((storefrontRuntime.isWorking && !installing) || store.workspaceURL == nil)
                            }
                        }
                    }
                }
            }
            } else {
                if storeSignInURL == nil {
                    InAppBrowserView(session: selectedStoreBrowserSession,
                                     close: { selectPage(apps: false) },
                                     closeTitle: "Games",
                                     storeBrand: provider == .epic ? "EPIC GAMES STORE" : "GOG STORE",
                                     storeAccountActionTitle: "My Games",
                                     storeAccountAction: { storeAppShowingLibrary = true },
                                     showAddressBar: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    private func refreshStoreApp(_ provider: WindowsStorefront) async {
        if provider == .epic { await storefrontRuntime.refreshEpicGames(workspace: store.workspaceURL) }
        else { await storefrontRuntime.refreshGOGGames(workspace: store.workspaceURL) }
        store.mergeOwnedStoreGames(provider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames, provider: provider)
        storeAppShowingLibrary = true
    }
    private func performStoreAppGameAction(_ item: WindowsStoreGame, game: Game, provider: WindowsStorefront) {
        if item.isInstalled { store.launch(game); return }
        Task {
            await storefrontRuntime.install(item, provider: provider, workspace: store.workspaceURL)
            store.mergeOwnedStoreGames(provider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames, provider: provider)
            await store.scan()
        }
    }
    @MainActor private func refreshStorefrontLibrary() async {
        let provider = storefrontRuntime.selectedProvider
        if provider == .epic { await storefrontRuntime.refreshEpicGames(workspace: store.workspaceURL) }
        else { await storefrontRuntime.refreshGOGGames(workspace: store.workspaceURL) }
        store.mergeOwnedStoreGames(provider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames, provider: provider)
    }
    private func mergeOwnedStoreGames(for provider: WindowsStorefront) {
        store.mergeOwnedStoreGames(provider == .epic ? storefrontRuntime.epicGames : storefrontRuntime.gogGames, provider: provider)
    }
    private func storefrontGame(_ item: WindowsStoreGame, provider: WindowsStorefront) -> Game {
        let source: GameSource = provider == .epic ? .epic : .gog
        let gameID = provider == .epic ? "legendary:\(item.id)" : "gog:\(item.id)"
        let installPath = item.installedPath ?? "/MetalOS/not-installed/\(item.id)"
        let cached = store.data.games.first { $0.id == gameID }
        return Game(id: gameID, title: item.title, source: source,
                    launchURL: "metalos-store://\(provider == .epic ? "epic" : "gog")/\(item.id)", installPath: installPath,
                    artworkPath: item.executableIconPath ?? cached?.artworkPath,
                    boxArt: cached?.boxArt, heroArt: cached?.heroArt,
                    artworkMatchedTitle: cached?.artworkMatchedTitle,
                    windowsStoreProvider: provider == .epic ? "epic" : "gog", windowsStoreGameID: item.id,
                    windowsGraphicsBackend: cached?.windowsGraphicsBackend ?? .automatic,
                    windowsGraphicsBackendUserSet: cached?.windowsGraphicsBackendUserSet ?? false,
                    windowsCompatibilityRuntime: cached?.windowsCompatibilityRuntime)
    }
    private func performPrimaryHomeGameAction(_ game: Game) {
        if game.windowsBottlePath != nil && game.windowsExecutablePath == nil {
            preparedBottleExecutableGameID = game.id
            return
        }
        if let provider = game.windowsStoreProvider.flatMap({ $0 == "epic" ? WindowsStorefront.epic : $0 == "gog" ? .gog : nil }),
           let gameID = game.windowsStoreGameID {
            if storefrontRuntime.isInstallingGame && storefrontRuntime.installGameID == gameID && storefrontRuntime.installProvider == provider {
                storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall()
            } else if !game.isAvailable {
                Task {
                    await storefrontRuntime.install(WindowsStoreGame(id: gameID, title: game.title), provider: provider, workspace: store.workspaceURL)
                    mergeOwnedStoreGames(for: provider)
                    await store.scan()
                }
            } else {
                store.launch(game)
            }
        } else {
            store.launch(game)
        }
    }
    @ViewBuilder private func storeGameActions(_ game: Game) -> some View {
        if let provider = game.windowsStoreProvider.flatMap({ $0 == "epic" ? WindowsStorefront.epic : $0 == "gog" ? .gog : nil }),
           let gameID = game.windowsStoreGameID {
            let item = WindowsStoreGame(id: gameID, title: game.title, installedPath: game.isAvailable ? game.installPath : nil)
            let installing = storefrontRuntime.isInstalling(item, provider: provider)
            HStack(spacing: 7) {
                if installing {
                    Button(storefrontRuntime.isInstallPaused ? "Resume" : "Pause") {
                        storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall()
                    }.buttonStyle(ConsoleButtonStyle())
                    Button("Stop") { storefrontRuntime.cancelInstall() }.buttonStyle(ConsoleButtonStyle())
                } else if game.isAvailable {
                    Button("Play") { store.launch(game) }.buttonStyle(ConsoleButtonStyle())
                    Button("Uninstall") { pendingStoreUninstall = (item, provider) }.buttonStyle(ConsoleButtonStyle())
                } else {
                    Button("Install") { performPrimaryHomeGameAction(game) }.buttonStyle(ConsoleButtonStyle())
                }
            }.frame(maxWidth: .infinity)
                .disabled((storefrontRuntime.isWorking && !installing) || store.workspaceURL == nil)
        }
    }
    @ViewBuilder private func gameMenu(_ game: Game) -> some View {
        Button("Game options…") { openContext(for: game) }
        Button("Game details…") { openGameDetails(game) }
        let isPreparedBottle = game.windowsBottlePath != nil && game.windowsExecutablePath == nil
        Button(isPreparedBottle ? "Choose game executable" : game.windowsStoreProvider != nil && !game.isAvailable ? "Install game" : "Play game") { performPrimaryHomeGameAction(game) }
            .disabled(!game.isAvailable && game.windowsStoreProvider == nil && !isPreparedBottle)
        if let provider = game.windowsStoreProvider.flatMap({ $0 == "epic" ? WindowsStorefront.epic : $0 == "gog" ? .gog : nil }),
           let gameID = game.windowsStoreGameID {
            if game.isAvailable {
                Button("Uninstall game…", role: .destructive) {
                    pendingStoreUninstall = (WindowsStoreGame(id: gameID, title: game.title, installedPath: game.installPath), provider)
                }
            } else {
                Button("Install game") {
                    Task {
                        await storefrontRuntime.install(WindowsStoreGame(id: gameID, title: game.title), provider: provider, workspace: store.workspaceURL)
                        await store.scan()
                    }
                }.disabled(storefrontRuntime.isWorking || store.workspaceURL == nil)
            }
        }
        Button(game.favorite ? "Remove favorite" : "Favorite") { store.favorite(game) }
        if game.source == .nxnative { Button("Build & configure…") { store.selectedID = game.id; store.showBuild = true } }
        Button("Remove from library", role: .destructive) { requestRemoval(game) }
    }
    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A place for every game.").font(.system(size: 46, weight: .light)).tracking(-1.5)
            Text(store.showingApps ? "Your apps and captured game media will appear here." : store.data.games.contains(where: \.isGame) ? "No games match your search." : "Add a game app or prepare a Switch title from its folder.")
                .font(.system(size: 15, weight: .light)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if store.showingApps {
                    Button("Add app") { store.importApp() }.buttonStyle(.borderedProminent).foregroundStyle(studioBackground)
                } else {
                    Button("Add Switch game") { store.showImport = true }.buttonStyle(.borderedProminent).foregroundStyle(studioBackground)
                    Button("Add game app") { store.importApp() }.buttonStyle(.bordered)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack(spacing: 24) {
            hint("A", libraryPage ? "Install app" : appsPage ? "Open app" : "Play game"); hint("X", "Options"); hint("☰", "Options"); hint("PS / P", "Control Center"); hint("LB / RB", "Games / Apps"); hint("LB + RB + ☰", "Game Bar")
            Spacer()
            if store.isScanning { ProgressView().controlSize(.mini); Text("Discovering games") }
            else if store.builder.isBuilding { Button("Build in progress") { store.showBuild = true }.buttonStyle(ConsoleButtonStyle()) }
            else { Text(libraryPage ? "\(PlatformApp.allCases.count) apps" : browserPage ? browserSession.pageTitle : "\(appsPage ? installedPlatformApps.count : store.visibleGames.count) \(appsPage ? "apps" : "games")") }
            Circle().fill(controller.name == nil ? .white.opacity(0.2) : studioAccent).frame(width: 5, height: 5)
            Button { showControllerStatus = true } label: { ControllerBatteryBadge() }.buttonStyle(ConsoleButtonStyle())
                .help("Controller status").accessibilityLabel("Controller status")
                .contextMenu { Button("Controller guide") { help = true } }
        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).frame(height: 46)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 7) { Text(key).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.7)); Text(title) }
    }
    private func openContext(for game: Game) {
        welcomeSelected = false; addCardSelected = false; store.selectedID = game.id; contextIndex = 0; contextGameID = game.id; libraryFocused = true
    }
    private func openGameDetails(_ game: Game) {
        welcomeSelected = false
        addCardSelected = false
        store.selectedID = game.id
        detailsActionIndex = 0
        detailsScrollTarget = 0
        detailsGameID = game.id
        if !store.console { libraryFocused = true }
    }
    private func handleGameDetailAction(_ action: GameDetailAction) {
        guard let game = detailsGameID.flatMap({ id in store.data.games.first { $0.id == id } }) else { return }
        switch action {
        case .play:
            if game.windowsBottlePath != nil && game.windowsExecutablePath == nil {
                preparedBottleExecutableGameID = game.id
            } else {
                detailsGameID = nil
                store.launch(game)
            }
        case .favorite:
            store.favorite(game)
        case .artwork:
            store.fetchArtwork(gameID: game.id, force: true)
        case .build:
            detailsGameID = nil
            store.selectedID = game.id
            store.showBuild = true
        case .bottleTools:
            break
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installPath)])
        }
    }
    private enum ContextAction: String {
        case play, details, favorite, build, uninstall, remove
        var symbol: String {
            switch self {
            case .play: "play.fill"
            case .details: "info.circle"
            case .favorite: "heart"
            case .build: "hammer"
            case .uninstall: "trash"
            case .remove: "minus.circle"
            }
        }
    }
    private func contextActions(for game: Game) -> [ContextAction] {
        var actions: [ContextAction] = [.play, .details, .favorite]
        if game.source == .nxnative { actions.append(.build) }
        if game.windowsStoreProvider != nil && game.windowsStoreGameID != nil && game.isAvailable { actions.append(.uninstall) }
        actions.append(.remove)
        return actions
    }
    private func contextTitle(_ action: ContextAction, game: Game) -> String {
        switch action {
        case .play:
            if game.windowsBottlePath != nil && game.windowsExecutablePath == nil { "Choose game executable" }
            else { game.windowsStoreProvider != nil && !game.isAvailable ? "Install game" : "Play game" }
        case .details: "View game details"
        case .favorite: game.favorite ? "Remove favorite" : "Add to favorites"
        case .build: "Build Studio"
        case .uninstall: "Uninstall game"
        case .remove: "Remove from library"
        }
    }
    @ViewBuilder private var contextOverlay: some View {
        ZStack(alignment: .trailing) {
            if let id = contextGameID, let game = store.data.games.first(where: { $0.id == id }) {
                Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { contextGameID = nil; libraryFocused = true }
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        Text("GAME OPTIONS").font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(studioAccent)
                        Spacer()
                        Button { contextGameID = nil; libraryFocused = true } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                                .background(.white.opacity(0.07), in: Circle())
                        }
                        .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close game options")
                    }
                    HStack(spacing: 14) {
                        GameIcon(game: game, artworkMode: .fill).frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(game.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            HStack(spacing: 6) {
                                Circle().fill(game.isAvailable ? studioAccent : .orange).frame(width: 5, height: 5)
                                Text(game.isAvailable ? (game.launchURL.isEmpty ? "PLAY TO PREPARE" : "READY TO PLAY") : game.windowsStoreProvider != nil ? "READY TO INSTALL" : "DRIVE OFFLINE")
                                    .font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(.white.opacity(0.56))
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.bottom, 3)
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                    VStack(spacing: 5) {
                        ForEach(Array(contextActions(for: game).enumerated()), id: \.element.rawValue) { index, action in
                            if action == .remove { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 5) }
                            Button { performContextAction(action, game: game) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: action.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                                    Text(contextTitle(action, game: game)).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    if index == contextIndex { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                                }.padding(.horizontal, 13).frame(height: 43)
                                    .foregroundStyle(index == contextIndex ? .white : action == .remove ? .red.opacity(0.85) : .white.opacity(0.84))
                                    .background(index == contextIndex ? (action == .remove ? Color.red.opacity(0.78) : studioAccent) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(ConsoleButtonStyle()).consoleFocus(index == contextIndex, cornerRadius: 8, scale: 1.015).accessibilityAddTraits(index == contextIndex ? [.isSelected] : [])
                        }
                    }
                    HStack { Text("↑ ↓  Choose"); Spacer(); Text("A / ✕  Select    B / ○  Back") }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
                }.padding(21).frame(width: 390).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.13)))
                    .overlay(alignment: .top) { Capsule().fill(studioAccent.opacity(0.9)).frame(width: 68, height: 2).padding(.top, 1) }
                    .shadow(color: .black.opacity(0.4), radius: 35, y: 15)
                    .padding(.trailing, 34).padding(.vertical, 36)
                    .transition(feedback.motionReduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }.zIndex(50)
    }
    private func performContextAction(_ action: ContextAction, game: Game) {
        contextGameID = nil; libraryFocused = true
        switch action {
        case .play: performPrimaryHomeGameAction(game)
        case .details: openGameDetails(game)
        case .favorite: store.favorite(game)
        case .build: store.selectedID = game.id; store.showBuild = true
        case .uninstall:
            if let provider = game.windowsStoreProvider.flatMap({ $0 == "epic" ? WindowsStorefront.epic : $0 == "gog" ? .gog : nil }),
               let gameID = game.windowsStoreGameID {
                pendingStoreUninstall = (WindowsStoreGame(id: gameID, title: game.title, installedPath: game.installPath), provider)
            }
        case .remove: requestRemoval(game)
        }
    }
    private func requestRemoval(_ game: Game) { pendingRemoval = game }
    private func selectPage(apps: Bool) {
        appsPage = apps
        libraryPage = false
        storeAppPage = false
        browserPage = false
        store.showingApps = apps
        store.source = .all
        store.selectedID = store.visibleGames.first?.id
        welcomeSelected = !apps && store.visibleGames.isEmpty
        addCardSelected = false
        selectedStoreTile = nil
        homeRow = 0
        topIndex = apps ? 1 : 0
        selectedPlatformAppIndex = 0
        libraryFocused = true
    }
    private func selectLibraryPage(provider: WindowsStorefront? = nil) {
        appsPage = false
        libraryPage = true
        storeAppPage = false
        browserPage = false
        store.showingApps = false
        if let provider { storefrontRuntime.selectedProvider = provider }
        selectedStoreCatalogIndex = 0
        store.source = .all
        selectedStoreTile = nil
        homeRow = 1
        topIndex = 0
        libraryFocused = true
    }
    private func selectBrowserPage() {
        appsPage = false
        libraryPage = false
        storeAppPage = false
        browserPage = true
        store.showingApps = false
        homeRow = 1
        topIndex = 0
        libraryFocused = true
    }
    private func selectStoreApp(_ provider: WindowsStorefront) {
        storefrontRuntime.selectedProvider = provider
        storeAppShowingLibrary = false
        let address = provider == .epic ? "https://store.epicgames.com/en-US/" : "https://www.gog.com/"
        selectedStoreBrowserSession.loadAddress(address)
        appsPage = false
        libraryPage = false
        storeAppPage = true
        browserPage = false
        store.showingApps = false
        selectedStoreTile = nil
        storeAppFocusZone = 1
        storeAppActionIndex = 0
        storeAppGameIndex = 0
        homeRow = 1
        libraryFocused = true
        Task { await refreshStorefrontLibrary() }
    }
    private var controlCenterOverlay: some View {
        Group {
            if controlCenterOpen {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.black.opacity(0.17)).background(.ultraThinMaterial).ignoresSafeArea()
                        .onTapGesture { controlCenterOpen = false; libraryFocused = true }
                        .transition(.opacity)
                    VStack(alignment: .leading, spacing: 17) {
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill").foregroundStyle(studioAccent)
                            Text("CONTROL CENTER").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.68))
                            if let game = store.selected {
                                Text("·").foregroundStyle(.white.opacity(0.3))
                                Text(game.title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white.opacity(0.84))
                            }
                            Spacer()
                            Text("PS / Home to close").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                        }
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 11) {
                                    controlCard(0, "Resume", store.selected?.launchURL.isEmpty == false ? "Return to your game" : "Open selected game", "play.fill")
                                    controlCard(1, "Apps", "Open installed platforms", "square.grid.2x2")
                                    controlCard(2, "Game Bar", "Capture and session tools", "slider.horizontal.3")
                                    controlCard(3, store.selected?.source == .nxnative ? "Build Studio" : "Games", store.builder.isBuilding ? "Build in progress" : "Return to games", store.selected?.source == .nxnative ? "hammer.fill" : "gamecontroller.fill")
                                    controlCard(4, "Accessories", "Controller status and setup", "gamecontroller")
                                    controlCard(5, "Settings", "Console and library", "gearshape")
                                }.padding(.vertical, 3).padding(.horizontal, 2)
                            }.onChange(of: controlCenterIndex) { _, index in
                                withAnimation(feedback.focusAnimation) { proxy.scrollTo(index, anchor: .center) }
                            }
                        }
                        HStack(spacing: 22) {
                            Text("A / ✕  Select")
                            Text("← →  Choose")
                            Spacer()
                            if store.builder.isBuilding {
                                ProgressView(value: store.builder.progress).tint(studioAccent).frame(width: 150)
                                Text("BUILDING").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(studioAccent)
                            }
                        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.48))
                    }.padding(20).frame(maxWidth: 1120).background(.ultraThinMaterial.opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.14)))
                        .shadow(color: .black.opacity(0.38), radius: 38, y: 16)
                        .padding(.horizontal, 30).padding(.bottom, 26)
                        .transition(feedback.motionReduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }.zIndex(60)
            }
        }
    }
    private func controlCard(_ index: Int, _ title: String, _ subtitle: String, _ symbol: String) -> some View {
        Button { performControlAction(index) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(studioAccent).frame(width: 22)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.54)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(14).frame(width: 168, height: 70, alignment: .leading)
                .background(.white.opacity(index == controlCenterIndex ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(index == controlCenterIndex ? 0.22 : 0.08)))
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(index == controlCenterIndex, cornerRadius: 12, scale: 1.025)
            .id(index)
            .accessibilityAddTraits(index == controlCenterIndex ? [.isSelected] : [])
    }
    private func performControlAction(_ index: Int) {
        switch index {
        case 0:
            controlCenterOpen = false
            if let game = store.selected { store.launch(game) }
        case 1:
            controlCenterOpen = false; selectPage(apps: true)
        case 2:
            controlCenterOpen = false; GameOverlayController.shared.showFromLibrary()
        case 3:
            controlCenterOpen = false
            if store.selected?.source == .nxnative { store.showBuild = true }
            else { selectPage(apps: false) }
        case 4: controlCenterOpen = false; showControllerStatus = true
        default: controlCenterOpen = false; store.showSettings = true
        }
        libraryFocused = true
    }
    private func handleNavigationKey(_ command: String) -> KeyPress.Result {
        guard navigationActive && !browserPage else { return .ignored }
        navigate(command)
        return .handled
    }
    private func navigate(_ command: String) {
        if handleProfileUpdateToast(command) { return }
        if command == "home", !controlCenterOpen {
            controlCenterOpen = true
            return
        }
        if controlCenterOpen {
            switch command {
            case "left", "previous": controlCenterIndex = max(controlCenterIndex - 1, 0)
            case "right", "next": controlCenterIndex = min(controlCenterIndex + 1, 5)
            case "confirm": performControlAction(controlCenterIndex)
            case "back", "menu", "context", "home": controlCenterOpen = false; libraryFocused = true
            default: break
            }
            return
        }
        if help { if ["back", "confirm", "menu"].contains(command) { help = false }; return }
        if let detailsGameID, let game = store.data.games.first(where: { $0.id == detailsGameID }) {
            let actions = GameDetailsView.actions(for: game)
            switch command {
            case "left", "previous": detailsActionIndex = max(0, detailsActionIndex - 1)
            case "right", "next": detailsActionIndex = min(actions.count - 1, detailsActionIndex + 1)
            case "up": detailsScrollTarget = max(0, detailsScrollTarget - 1)
            case "down": detailsScrollTarget = min(1, detailsScrollTarget + 1)
            case "confirm": handleGameDetailAction(actions[min(detailsActionIndex, actions.count - 1)])
            case "favorite": store.favorite(game)
            case "back": self.detailsGameID = nil
            case "menu", "context": openContext(for: game)
            default: break
            }
            return
        }
        if let id = contextGameID, let game = store.data.games.first(where: { $0.id == id }) {
            let actions = contextActions(for: game)
            switch command {
            case "up", "left": contextIndex = (contextIndex - 1 + actions.count) % actions.count
            case "down", "right": contextIndex = (contextIndex + 1) % actions.count
            case "confirm": performContextAction(actions[min(contextIndex, actions.count - 1)], game: game)
            case "back", "menu", "context": contextGameID = nil; libraryFocused = true
            default: break
            }
            return
        }
        if searchOpen {
            if command == "back" { searchOpen = false; libraryFocused = true }; return
        }
        if store.showSettings || store.showGameImport || store.showImport || store.showBuild || settingsShowTester {
            if command == "back" {
                store.showGameImport = false
                store.showSettings = false
                store.showImport = false
                store.showBuild = false
                settingsShowTester = false
            }; return
        }
        switch command {
        case "left", "right":
            let delta = command == "left" ? -1 : 1
            if homeRow == 0 { topIndex = min(max(topIndex + delta, 0), 4) }
            else if storeAppPage {
                if storeAppFocusZone == 1 {
                    let maxAction = storefrontRuntime.isInstallingGame && storefrontRuntime.installProvider == storefrontRuntime.selectedProvider ? 3 : 1
                    storeAppActionIndex = min(max(storeAppActionIndex + delta, 0), maxAction)
                } else if storeAppFocusZone == 2 {
                    let current = storefrontGames.indices.contains(storeAppGameIndex) ? storefrontGames[storeAppGameIndex] : nil
                    let hasSecondAction = current.map { $0.isInstalled || storefrontRuntime.isInstalling($0, provider: storefrontRuntime.selectedProvider) } ?? false
                    if delta > 0 && hasSecondAction && storefrontGameAction == 0 { storefrontGameAction = 1 }
                    else if delta < 0 && storefrontGameAction > 0 { storefrontGameAction = 0 }
                    else {
                        let target = storeAppGameIndex + delta
                        if target >= 0 && target < storefrontGames.count && target / columns == storeAppGameIndex / columns {
                            storeAppGameIndex = target
                            storefrontGameAction = 0
                        }
                    }
                }
            }
            else if libraryPage { selectedStoreCatalogIndex = min(max(selectedStoreCatalogIndex + delta, 0), PlatformApp.allCases.count - 1) }
            else if browserPage { }
            else if selectedStoreTile != nil {
                if delta > 0 { selectedStoreTile = nil; welcomeSelected = true }
            }
            else if appsPage && homeRow == 1 {
                selectedPlatformAppIndex = min(max(selectedPlatformAppIndex + delta, 0), max(installedPlatformApps.count - 1, 0))
            }
            else if homeRow == 2 && !appsPage {
                actionIndex = min(max(actionIndex + delta, 0), 1)
            }
            else if homeRow == 3 && welcomeSelected {
                let rowStart = (welcomeCardIndex / 3) * 3
                let column = welcomeCardIndex % 3
                welcomeCardIndex = rowStart + min(max(column + delta, 0), 2)
            }
            else if homeRow == 3 && !welcomeSelected && gameScreenshotSelectionCount > 0 {
                gameScreenshotIndex = min(max(gameScreenshotIndex + delta, 0), gameScreenshotSelectionCount - 1)
            }
            else if !appsPage {
                let games = store.visibleGames
                if welcomeSelected {
                    if delta < 0 { welcomeSelected = false; selectedStoreTile = 0 }
                    else {
                        if games.isEmpty { welcomeSelected = false; addCardSelected = true }
                        else { welcomeSelected = false; store.selectedID = games.first?.id }
                    }
                } else if addCardSelected {
                    if delta < 0 {
                        addCardSelected = false
                        if games.isEmpty { welcomeSelected = true }
                        else { store.selectedID = games.last?.id }
                    }
                } else if let index = games.firstIndex(where: { $0.id == store.selected?.id }) {
                    if delta < 0 && index == 0 { welcomeSelected = true }
                    else if delta > 0 && index == games.count - 1 { addCardSelected = true }
                    else { store.moveSelection(delta) }
                }
            } else if appsPage { }
            else { moveMediaSelection(horizontal: delta) }
        case "up":
            if storeAppPage {
                if storeAppFocusZone == 2 && storeAppGameIndex >= columns { storeAppGameIndex -= columns; storefrontGameAction = 0 }
                else if storeAppFocusZone == 2 { storeAppFocusZone = 1; storeAppActionIndex = 0 }
                else { homeRow = 0; topIndex = 0 }
            } else if libraryPage && homeRow != 0 { homeRow = 0; topIndex = 0 }
            else if appsPage && homeRow != 0 {
                homeRow = 0
                topIndex = 1
            } else if !appsPage && !welcomeSelected && homeRow == 3 { homeRow = 2 }
            else if !appsPage && welcomeSelected && homeRow == 3 {
                if welcomeCardIndex >= 3 { welcomeCardIndex -= 3 }
                else { homeRow = 2 }
            } else { homeRow = max(homeRow - 1, 0) }
        case "down":
            if homeRow == 0 { homeRow = 1 }
            else if storeAppPage {
                if storeAppFocusZone == 1 { storeAppFocusZone = 2; storeAppGameIndex = min(storeAppGameIndex, max(storefrontGames.count - 1, 0)) }
                else if storeAppFocusZone == 2 { storeAppGameIndex = min(storeAppGameIndex + columns, max(storefrontGames.count - 1, 0)); storefrontGameAction = 0 }
            }
            else if libraryPage { }
            else if appsPage { selectedPlatformAppIndex = min(selectedPlatformAppIndex + columns, max(installedPlatformApps.count - 1, 0)) }
            else if welcomeSelected && homeRow == 3 { welcomeCardIndex = min(welcomeCardIndex + 3, 5) }
            else if !welcomeSelected && homeRow == 2 && gameScreenshotSelectionCount == 0 { }
            else { homeRow = min(homeRow + 1, 3) }
        case "confirm":
            if homeRow == 0 {
                switch topIndex {
                case 0: selectPage(apps: false)
                case 1: selectPage(apps: true)
                case 2: searchOpen = true
                case 3: store.showSettings = true
                case 4: showingNotificationCenter = true
                default: break
                }
            } else if storeAppPage {
                if storeAppFocusZone == 1 {
                    if storeAppActionIndex == 0 {
                        if !storefrontRuntime.toolInstalled(for: storefrontRuntime.selectedProvider) {
                            Task {
                                if storefrontRuntime.selectedProvider == .epic { await storefrontRuntime.installLegendary(workspace: store.workspaceURL) }
                                else { await storefrontRuntime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
                            }
                        } else {
                            let provider = storefrontRuntime.selectedProvider
                            storeSignInURL = provider == .epic ? storefrontRuntime.epicLoginURL(workspace: store.workspaceURL) : storefrontRuntime.gogLoginURL()
                            signInProvider = provider
                        }
                    } else if storeAppActionIndex == 1 { Task { await refreshStoreApp(storefrontRuntime.selectedProvider) } }
                    else if storeAppActionIndex == 2 { storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall() }
                    else if storeAppActionIndex == 3 { storefrontRuntime.cancelInstall() }
                } else if storeAppFocusZone == 2 && storefrontGames.indices.contains(storeAppGameIndex) {
                    let item = storefrontGames[storeAppGameIndex]
                    let game = storefrontGame(item, provider: storefrontRuntime.selectedProvider)
                    let provider = storefrontRuntime.selectedProvider
                    if storefrontRuntime.isInstalling(item, provider: provider) {
                        if storefrontGameAction == 0 { storefrontRuntime.isInstallPaused ? storefrontRuntime.resumeInstall() : storefrontRuntime.pauseInstall() }
                        else { storefrontRuntime.cancelInstall() }
                    } else if item.isInstalled {
                        if storefrontGameAction == 0 { store.launch(game) }
                        else { pendingStoreUninstall = (item, provider) }
                    } else if storefrontGameAction == 0 { performStoreAppGameAction(item, game: game, provider: provider) }
                }
            } else if libraryPage {
                if PlatformApp.allCases.indices.contains(selectedStoreCatalogIndex) {
                    selectStorePlatform(PlatformApp.allCases[selectedStoreCatalogIndex])
                }
            } else if appsPage && homeRow == 1 {
                if installedPlatformApps.indices.contains(selectedPlatformAppIndex) {
                    launchPlatformApp(installedPlatformApps[selectedPlatformAppIndex])
                }
            } else if browserPage {
                break
            } else if homeRow == 1 && !appsPage {
                if selectedStoreTile == 0 { selectLibraryPage() }
                else if addCardSelected { store.importApp() }
                else if !welcomeSelected, let game = store.selected { performPrimaryHomeGameAction(game) }
            } else if homeRow == 2 && !appsPage {
                if welcomeSelected { if actionIndex == 0 { selectLibraryPage() } else { store.importApp() } }
                else if let game = store.selected {
                    if actionIndex == 0 { performPrimaryHomeGameAction(game) }
                    else if storefrontRuntime.isInstallingGame && storefrontRuntime.installGameID == game.windowsStoreGameID && actionIndex == 1 {
                        storefrontRuntime.cancelInstall()
                    } else if actionIndex == 1 {
                        if storefrontRuntime.isInstallingGame && storefrontRuntime.installGameID == game.windowsStoreGameID { storefrontRuntime.cancelInstall() }
                        else { openContext(for: game) }
                    }
                } else { store.showImport = true }
            } else if homeRow == 3 {
                if welcomeSelected { performWelcomeCard(welcomeCardIndex) }
                else if let screenshots = store.selected?.metadata?.screenshots, screenshots.indices.contains(gameScreenshotIndex) {
                    selectedGameScreenshot = screenshots[gameScreenshotIndex]
                }
            } else if let game = store.selected { store.launch(game) }
            else { store.importApp() }
        case "favorite": if let game = store.selected { store.favorite(game) }
        case "previous", "next":
            if browserPage { selectPage(apps: false); break }
            let delta = command == "next" ? 1 : -1
            selectPage(apps: appsPage ? delta < 0 : delta > 0)
        case "back":
            if searchOpen { searchOpen = false }
            else if homeRow != 1 { homeRow = 1 }
            else if appsPage || libraryPage || storeAppPage || browserPage { selectPage(apps: false) }
            else if store.console { store.toggleConsole() }
        case "menu", "context": if let game = store.selected { openContext(for: game) } else { store.importApp() }
        case "details": if let game = store.selected { openContext(for: game) }
        default: break
        }
    }

    private func moveMediaSelection(horizontal deltaX: Int = 0, vertical deltaY: Int = 0) {
        let games = store.visibleGames
        guard !games.isEmpty else { return }
        let index = games.firstIndex(where: { $0.id == store.selected?.id }) ?? 0
        let row = index / columns
        let column = index % columns
        let target: Int
        if deltaX != 0 {
            let nextColumn = column + deltaX
            guard (0..<columns).contains(nextColumn) else { return }
            target = row * columns + nextColumn
        } else if deltaY != 0 {
            let nextRow = row + deltaY
            guard nextRow >= 0 else { return }
            let rowStart = nextRow * columns
            guard rowStart < games.count else { return }
            target = min(rowStart + column, min(rowStart + columns, games.count) - 1)
        } else { return }
        guard games.indices.contains(target) else { return }
        store.selectedID = games[target].id
    }

    private func handleProfileUpdateToast(_ command: String) -> Bool {
        guard let updated = profileUpdateGame else { return false }
        switch command {
        case "left", "up", "previous": profileToastAction = 0
        case "right", "down", "next": profileToastAction = 1
        case "confirm":
            if profileToastAction == 0 { openProfileUpdate(updated) }
            else { dismissProfileUpdate(updated) }
        case "back", "menu", "context": dismissProfileUpdate(updated)
        default: return false
        }
        return true
    }
    private func openProfileUpdate(_ game: Game) {
        welcomeSelected = false
        addCardSelected = false
        homeRow = 1
        store.selectedID = game.id
        store.showBuild = true
        libraryFocused = true
    }
    private func dismissProfileUpdate(_ game: Game) {
        dismissedProfileToastKey = profileToastKey(for: game)
        profileToastAction = 0
    }
    private func profileToastKey(for game: Game) -> String {
        "\(game.id)|\(game.nxSupport?.latestProfileRevision ?? "")"
    }
}

private struct BuildProgressToast: View {
    @ObservedObject var builder: NXBuildService
    let gameTitle: String
    let showBuild: () -> Void
    @State private var visible = true
    var body: some View {
        Group {
            if visible {
                HStack(spacing: 14) {
                    Image(systemName: "hammer.fill").foregroundStyle(studioAccent)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("BUILDING · \(gameTitle)").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(studioAccent)
                            Spacer()
                            Text(builder.elapsedLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let progress = builder.progress { Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()) }
                            Button("Show", action: showBuild).font(.caption.weight(.semibold))
                                .consoleFocus(true, cornerRadius: 7, scale: 1.08)
                                .accessibilityLabel("Show build progress. Press A")
                        }
                        Text(builder.activePhase).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        if let progress = builder.progress { ProgressView(value: progress).tint(studioAccent) }
                        else { ProgressView().tint(studioAccent) }
                    }
                }
                .padding(15).frame(width: 520)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(studioAccent.opacity(0.35)))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 9)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { visible = false }
        }
    }
}

private struct StorefrontNotificationToast: View {
    let notification: StorefrontNotification
    @ObservedObject var runtime: WindowsStorefrontRuntime
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.isActive ? "arrow.down.circle.fill" : notification.title.localizedCaseInsensitiveContains("complete") || notification.title.localizedCaseInsensitiveContains("uninstalled") ? "checkmark.circle.fill" : "bell.badge.fill")
                .font(.system(size: 21)).foregroundStyle(studioAccent).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notification.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if !notification.isActive {
                        Button { runtime.dismissNotification(notification.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).accessibilityLabel("Dismiss notification")
                    }
                }
                Text(notification.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.66)).lineLimit(2)
                if let progress = notification.progress { ProgressView(value: progress).tint(studioAccent) }
                if notification.isActive, runtime.isInstallingGame {
                    HStack(spacing: 8) {
                        Button(runtime.isInstallPaused ? "Resume" : "Pause") {
                            runtime.isInstallPaused ? runtime.resumeInstall() : runtime.pauseInstall()
                        }.buttonStyle(.bordered).controlSize(.small)
                        Button("Stop", role: .destructive) { runtime.cancelInstall() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(14).frame(width: 350, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.13)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }
}

private struct HomeTile: View {
    let game: Game
    let selected: Bool
    let focused: Bool
    var building = false
    var progress: Double? = nil
    var installing = false
    var installationProgress: Double? = nil
    let select: () -> Void
    private var size: CGFloat { selected ? 158 : 106 }
    private var corner: CGFloat { selected ? 17 : 14 }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: corner).fill(.white.opacity(selected ? 0.09 : 0.045))
                    .frame(width: size, height: size)
                    .overlay {
                        GameIcon(game: game, artworkMode: .fill).padding(game.boxArt != nil || (game.windowsStoreProvider != nil && game.artworkPath != nil) || game.id.hasPrefix("windows-client:highball:") ? 0 : selected ? 16 : 12)
                    }
                    .overlay(alignment: .bottom) {
                        if installing {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 8))
                                    Text(installationProgress.map { "INSTALLING \(Int(($0 * 100).rounded()))%" } ?? "INSTALLING")
                                        .font(.system(size: 8, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                if let installationProgress { ProgressView(value: installationProgress).tint(studioAccent) }
                                else { ProgressView().tint(studioAccent) }
                            }.padding(7).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8)).padding(6)
                        } else if building {
                            VStack(spacing: 4) {
                                if let progress { ProgressView(value: progress).tint(studioAccent) }
                                else { ProgressView().tint(studioAccent) }
                            }.padding(7).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: corner))

                    .consoleFocus(focused, cornerRadius: corner, scale: 1.075)

                if selected {
                    Text(game.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading)
                }
            }.padding(.top, selected ? 0 : 8).frame(height: 190, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("\(game.title), \(game.source.rawValue)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .animation(ConsoleFeedback.shared.focusAnimation, value: selected)

    }
}
private struct StoreHomeTile: View {
    let selected: Bool
    let focused: Bool
    let open: () -> Void
    private var size: CGFloat { selected ? 158 : 106 }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: selected ? 17 : 14)
                    .fill(LinearGradient(colors: [studioAccent.opacity(0.25), studioAccent.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .overlay {
                        VStack(spacing: 7) {
                            Image(systemName: "bag.fill")
                                .font(.system(size: selected ? 40 : 30, weight: .light)).foregroundStyle(studioAccent)
                            if selected { Text("STORE").font(.system(size: 8, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.7)) }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: selected ? 17 : 14).strokeBorder(.white.opacity(selected ? 0.2 : 0.09)))
                    .consoleFocus(focused, cornerRadius: selected ? 17 : 14, scale: 1.075)
                if selected {
                    Text("Store").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading)
                }
            }.padding(.top, selected ? 0 : 8).frame(height: 190, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Store").accessibilityAddTraits(selected ? [.isSelected] : [])
            .animation(ConsoleFeedback.shared.focusAnimation, value: selected)
    }
}
private struct BrowserHomeTile: View {
    let selected: Bool
    let focused: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.04, green: 0.29, blue: 0.58).opacity(0.25))
                    .frame(width: 92, height: 92)
                    .overlay {
                        VStack(spacing: 7) {
                            Image(systemName: "safari.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.9))
                            Text("WEB").font(.system(size: 7, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(focused ? 0.3 : 0.09)))
                    .consoleFocus(focused, cornerRadius: 14, scale: 1.075)
                Text("Internet Browser").font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.72)).frame(width: 112, alignment: .leading)
            }.padding(.top, 8).frame(height: 162, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Open Internet Browser")
    }
}
private struct WelcomeTile: View {
    let selected: Bool
    let focused: Bool
    let select: () -> Void
    private var size: CGFloat { selected ? 158 : 106 }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: selected ? 17 : 14)
                        .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.26, blue: 0.58), Color(red: 0.025, green: 0.08, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(studioAccent.opacity(0.22)).frame(width: size * 0.72, height: size * 0.72).blur(radius: 16)
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: selected ? 38 : 27, weight: .ultraLight))
                        if selected { Text("WELCOME").font(.system(size: 8, weight: .bold)).tracking(2) }
                    }.foregroundStyle(.white.opacity(0.86))
                }.frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: selected ? 17 : 14).strokeBorder(.white.opacity(selected ? 0.18 : 0.09)))
                    .consoleFocus(focused, cornerRadius: selected ? 17 : 14, scale: 1.075)
                if selected { Text("Welcome").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading) }
            }.padding(.top, selected ? 0 : 8).frame(height: 190, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Welcome to MetalOS").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
private struct AddGameTile: View {
    let selected: Bool
    let focused: Bool
    let action: () -> Void
    private var size: CGFloat { selected ? 158 : 106 }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: selected ? 17 : 14).fill(.white.opacity(selected ? 0.075 : 0.04))
                    Image(systemName: "plus").font(.system(size: selected ? 38 : 28, weight: .ultraLight)).foregroundStyle(.white.opacity(0.62))
                }.frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: selected ? 17 : 14).strokeBorder(.white.opacity(selected ? 0.16 : 0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .consoleFocus(focused, cornerRadius: selected ? 17 : 14, scale: 1.075)
                if selected { Text("Add game").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading) }
            }.padding(.top, selected ? 0 : 8).frame(height: 190, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).help("Add a game or app").accessibilityLabel("Add a game or app").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
private struct HomeBackdrop: View {
    let game: Game?
    let wallpaperPath: String?

    private var gameArtworkPath: String? {
        [game?.heroArt?.path, game?.tileArt?.path, game?.artworkPath, game?.boxArt?.path]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private var videoWallpaperURL: URL? {
        guard let wallpaperPath,
              WallpaperPreset.fromStorageValue(wallpaperPath) == nil,
              ["mov", "mp4", "m4v", "qt"].contains(URL(fileURLWithPath: wallpaperPath).pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: wallpaperPath) else { return nil }
        return URL(fileURLWithPath: wallpaperPath)
    }

    private var imagePath: String? {
        if let gameArtworkPath { return gameArtworkPath }
        if wallpaperPath == nil, let url = WallpaperPreset.blueHorizon.imageURL { return url.path }
        if let preset = WallpaperPreset.fromStorageValue(wallpaperPath), let url = preset.imageURL { return url.path }
        if let wallpaperPath, videoWallpaperURL == nil, FileManager.default.fileExists(atPath: wallpaperPath) { return wallpaperPath }
        return WallpaperPreset.blueHorizon.imageURL?.path
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                studioBackground.ignoresSafeArea()
                if gameArtworkPath == nil, let videoWallpaperURL {
                    LoopingWallpaperVideo(url: videoWallpaperURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if let path = imagePath, let art = NSImage(contentsOfFile: path) {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .saturation(0.94).opacity(game == nil || path == game?.heroArt?.path ? 1 : 0.72)
                        .id(path).transition(.opacity)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.40), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.28),
                    .init(color: .clear, location: 0.68),
                    .init(color: .black.opacity(0.34), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.80), location: 0),
                    .init(color: .black.opacity(0.48), location: 0.30),
                    .init(color: .black.opacity(0.08), location: 0.78),
                    .init(color: .black.opacity(0.16), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }.animation(.easeInOut(duration: 0.35), value: game?.id)
                .animation(.easeInOut(duration: 0.35), value: game?.heroArt?.path)
                .animation(.easeInOut(duration: 0.35), value: wallpaperPath)
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct HomeParticleField: View {
    let enabled: Bool
    private let count = 68

    var body: some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<count {
                        let seed = Double(index)
                        let lane = (seed * 0.61803398875).truncatingRemainder(dividingBy: 1)
                        let drift = (lane + time * (0.004 + Double(index % 6) * 0.0016)).truncatingRemainder(dividingBy: 1)
                        let x = drift * size.width
                        let wave = 0.5 + 0.5 * sin(time * 0.19 + seed * 1.71)
                        let y = (0.12 + wave * 0.78) * size.height
                        let pulse = 0.5 + 0.5 * sin(time * 0.7 + seed * 2.3)
                        let radius = 0.8 + Double(index % 4) * 0.45
                        let opacity = 0.12 + pulse * 0.30
                        let glow = CGRect(x: x - radius * 3.5, y: y - radius * 3.5, width: radius * 7, height: radius * 7)
                        let core = CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius)
                        context.fill(Path(ellipseIn: glow), with: .color(Color(red: 0.38, green: 0.78, blue: 1).opacity(opacity * 0.16)))
                        context.fill(Path(ellipseIn: core), with: .color(.white.opacity(opacity)))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
/// Artwork never participates in sizing its container: the tile owns its geometry.
struct GameIcon: View {
    let game: Game
    var artworkMode: ContentMode = .fit
    var body: some View {
        GeometryReader { geometry in
            Group {
                if game.id == "windows-client:highball:steam" {
                    HighballClientArtwork(client: .steam)
                } else if game.id == "windows-client:highball:rockstar" {
                    HighballClientArtwork(client: .rockstar)
                } else if game.windowsStoreProvider != nil, let path = game.artworkPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else if artworkMode == .fill, let path = game.tileArt?.path, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if game.source == .nxnative, let path = game.artworkPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: artworkMode)
                } else if let path = game.boxArt?.path, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: artworkMode)
                } else if game.installPath.hasSuffix(".app"), game.isAvailable {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: game.installPath)).resizable().interpolation(.high).scaledToFit()
                } else if let path = game.artworkPath, let icon = NSImage(contentsOfFile: path) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [studioAccent.opacity(0.25), Color(red: 0.13, green: 0.22, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: game.source.symbol).resizable().scaledToFit().padding(20).foregroundStyle(studioAccent.opacity(0.8))
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
}
private struct HighballClientArtwork: View {
    enum Client: Equatable { case steam, rockstar }
    let client: Client
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 15).fill(
                    LinearGradient(colors: client == .steam
                                   ? [Color(red: 0.08, green: 0.34, blue: 0.53), Color(red: 0.035, green: 0.10, blue: 0.18)]
                                   : [Color(red: 0.20, green: 0.20, blue: 0.20), Color(red: 0.035, green: 0.035, blue: 0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                Circle().fill(.white.opacity(0.055))
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: proxy.size.width * 0.35, y: -proxy.size.height * 0.34)
                if client == .steam {
                    VStack(spacing: 9) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: min(proxy.size.width * 0.37, 46), weight: .light))
                            .foregroundStyle(.white)
                        Text("STEAM").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(2.6).foregroundStyle(.white.opacity(0.92))
                    }
                } else {
                    VStack(spacing: 7) {
                        if let url = Bundle.module.url(forResource: "rockstar-games-logo", withExtension: "png") ?? Bundle.main.url(forResource: "rockstar-games-logo", withExtension: "png"),
                           let logo = NSImage(contentsOf: url) {
                            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                                .frame(width: proxy.size.width * 0.64, height: proxy.size.width * 0.64)
                        } else {
                            Text("R*").font(.system(size: min(proxy.size.width * 0.32, 42), weight: .black, design: .rounded))
                                .foregroundStyle(.black).frame(width: proxy.size.width * 0.46, height: proxy.size.width * 0.46)
                                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("ROCKSTAR GAMES").font(.system(size: 7, weight: .heavy, design: .rounded)).tracking(1.1).foregroundStyle(.white.opacity(0.9))
                    }
                }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }.accessibilityHidden(true)
    }
}
struct GameCard: View {
    let game: Game
    let selected: Bool
    var focused = true
    var building = false
    var progress: Double? = nil
    var installing = false
    var installationProgress: Double? = nil
    let select: () -> Void
    let launch: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.035))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { GameIcon(game: game).padding(game.boxArt != nil || (game.windowsStoreProvider != nil && game.artworkPath != nil) || game.id.hasPrefix("windows-client:highball:") ? 0 : 24) }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if game.favorite { Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(studioAccent).padding(7).background(.black.opacity(0.6), in: Circle()) }
                        if !game.isAvailable { Text("OFFLINE").font(.system(size: 9, weight: .bold)).padding(8).background(.black.opacity(0.7), in: Capsule()) }
                    }.padding(10)
                }
                .overlay(alignment: .bottom) {
                    if installing {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                                Text(installationProgress.map { "INSTALLING · \(Int(($0 * 100).rounded()))%" } ?? "INSTALLING")
                                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                                Spacer(minLength: 0)
                            }
                            if let installationProgress { ProgressView(value: installationProgress).tint(studioAccent) }
                            else { ProgressView().tint(studioAccent) }
                        }.foregroundStyle(.white).padding(9)
                            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
                            .padding(9).frame(maxHeight: .infinity, alignment: .bottom)
                    } else if building {
                        HStack(spacing: 7) {
                            Image(systemName: "hammer.fill").font(.system(size: 9))
                            Text(progress.map { "BUILDING \(Int($0 * 100))%" } ?? "BUILDING")
                                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                            Spacer(minLength: 0)
                        }.foregroundStyle(studioBackground).padding(9)
                            .background(studioAccent.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
                            .padding(9).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))


            Text(game.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(game.source.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
        }.consoleFocus(selected && focused, cornerRadius: 14).contentShape(Rectangle()).onTapGesture(count: 2, perform: launch).onTapGesture(perform: select)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
    }
}

private struct HelpView: View {
    @Environment(\.consolePageClose) var closePage
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your controller. Your console.").font(.title.bold())
            Text("D-pad / left stick     Browse the Games rail or Apps\nA     Select or open\nB     Back\nY     Favorite\nPS / P     Control Center\nLB / RB     Switch between Games and Apps\nMenu / Options     Game options\nX     Game options\nLB + RB + Menu     In-game Game Bar")
                .lineSpacing(9)
            Text("The overlay offers quick access to your game and library. Games continue running while it is open.").foregroundStyle(.secondary)
            Button("Back to games") { closePage() }.keyboardShortcut(.cancelAction)
        }.padding(36).frame(width: 580)
            .consoleInput { command in
                if command == "back" || command == "menu" || command == "context" { closePage() }
            }
    }
}

private struct PreparedLutrisExecutablePage: View {
    let game: Game
    let onSelect: (URL) -> Void
    private var gameDriveC: URL? {
        guard let bottlePath = game.windowsBottlePath else { return nil }
        return WindowsRuntimeLayout.winePrefix(forBottleAt: URL(fileURLWithPath: bottlePath, isDirectory: true))
            .appendingPathComponent("drive_c", isDirectory: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("FINISH LUTRIS SETUP").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(studioAccent)
            Text(game.title).font(.system(size: 27, weight: .light))
            Text("Install the game and any patches in this bottle first. Then choose its main game executable from the bottle’s C: drive.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ConsoleFilePicker(title: "Choose the installed game executable", mode: .file,
                              startingPath: gameDriveC?.path, allowedExtensions: ["exe"], onSelect: onSelect)
        }
        .padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBackground.ignoresSafeArea()).preferredColorScheme(.dark)
    }
}
