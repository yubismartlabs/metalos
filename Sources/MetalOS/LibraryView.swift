import SwiftUI
import AppKit

let studioAccent = Color(red: 0.05, green: 0.46, blue: 0.96)
let studioBackground = Color(red: 0.025, green: 0.043, blue: 0.09)

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var controller = ControllerManager.shared
    @State private var appsPage = false
    @State private var searchOpen = false
    @State private var pendingSwitchImport = false
    @State private var showControllerStatus = false
    @State private var controlCenterOpen = false
    @State private var controlCenterIndex = 0
    @State private var help = false
    @State private var browseInstallation: String?
    @State private var contextGameID: String?
    @State private var pendingRemoval: Game?
    @State private var contextIndex = 0
    @State private var homeRow = 1
    @State private var topIndex = 0
    @State private var actionIndex = 0
    @State private var welcomeCardIndex = 0
    @State private var welcomeSelected = true
    @State private var addCardSelected = false
    @State private var profileToastAction = 0
    @State private var dismissedProfileToastKey: String?
    @FocusState private var libraryFocused: Bool
    private let columns = 5
    private var navigationActive: Bool {
        controller.activeInputScopeID == nil && contextGameID == nil && browseInstallation == nil && !help && !controlCenterOpen && !store.showSettings && !store.showGameImport && !store.showImport && !store.showBuild && !searchOpen && !showControllerStatus && !settingsShowTester && store.notice == nil
    }
    private var welcomeGames: [Game] { store.data.games.filter(\.isGame) }
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
            } else if store.showSettings {
                SettingsView(isPage: true, onClose: { store.showSettings = false }).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else if store.showBuild {
                BuildView(gameID: store.selected?.id, onClose: { store.showBuild = false }).environmentObject(store)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            } else {
            ZStack {
                HomeBackdrop(game: welcomeSelected ? nil : store.selected)
                VStack(alignment: .leading, spacing: 0) {
                    navigationBar
                    if appsPage {
                        appsView.padding(.top, 18)
                    } else {
                        gameRail.padding(.top, 26)
                        if store.selected != nil && !welcomeSelected {
                            spotlight(compact: geometry.size.height < 780)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(.bottom, 20)
                            gameMetadataPanel.padding(.bottom, 18)
                        } else {
                            welcomeSpotlight(compact: geometry.size.height < 780)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(.bottom, 20)
                            welcomeMetadataPanel.padding(.bottom, 18)
                        }
                    }
                    footer
                }.padding(.horizontal, store.console ? 66 : 52).padding(.top, 38)
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
                if store.builder.isBuilding {
                    BuildProgressToast(builder: store.builder,
                                       gameTitle: store.data.games.first(where: { $0.id == store.builder.currentGameID })?.title ?? "Game",
                                       showBuild: { store.showBuild = true })
                }
                if let updated = profileUpdateGame {
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
        .animation(.easeInOut(duration: 0.2), value: store.builder.toastMessage)
        .animation(feedback.pageAnimation, value: store.showSettings)
        .animation(feedback.pageAnimation, value: store.showBuild)
        .animation(feedback.pageAnimation, value: appsPage)
        .onChange(of: store.visibleGames.count) { _, count in
            if !appsPage { welcomeSelected = count == 0; addCardSelected = false }
        }
        .onChange(of: store.showingApps) { _, value in
            appsPage = value
            topIndex = value ? 1 : 0
        }
        .consoleModalBackdrop(contextGameID != nil || store.notice != nil)
        .overlay { contextOverlay.animation(feedback.pageAnimation, value: contextGameID).animation(feedback.focusAnimation, value: contextIndex) }
        .overlay { controlCenterOverlay.animation(feedback.pageAnimation, value: controlCenterOpen).animation(feedback.focusAnimation, value: controlCenterIndex) }
        .background {
            LibraryKeyHandler(enabled: navigationActive) { command in
                navigate(command)
            }
        }
        .background(studioBackground).tint(studioAccent)
        .consoleSheet(isPresented: Binding(get: { browseInstallation != nil }, set: { if !$0 { browseInstallation = nil } })) {
            ConsoleFilePicker(title: "Game installation", mode: .file, startingPath: browseInstallation) { _ in browseInstallation = nil }
        }
        .consoleSheet(isPresented: $searchOpen, onDismiss: { libraryFocused = true }) {
            SearchKeyboardView(query: $store.query) { searchOpen = false }
        }
        .consoleSheet(isPresented: $showControllerStatus, onDismiss: { libraryFocused = true }) {
            ControllerStatusView()
        }
        .consoleSheet(isPresented: Binding(get: { settingsShowTester }, set: { settingsShowTester = $0 })) {
            GamepadTesterView()
        }
        .consoleSheet(isPresented: $store.showGameImport, onDismiss: {
            if pendingSwitchImport { pendingSwitchImport = false; store.showImport = true }
        }) {
            AddGameView { pendingSwitchImport = true; store.showGameImport = false }.environmentObject(store)
        }
        .consoleSheet(isPresented: $store.showImport, onDismiss: {
            if store.openBuildAfterImport { store.openBuildAfterImport = false; store.showBuild = true }
        }) { SwitchImportView() }
        .consoleSheet(isPresented: $help) {
            HelpView()
        }
        .consoleSheet(isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            if let game = pendingRemoval {
                ActionConfirmationView(title: "Remove \(game.title)?", message: "This removes the game from your MetalOS library. Its app or game files will stay where they are.", confirmTitle: "Remove from library", destructive: true) {
                    store.removeGame(id: game.id)
                    pendingRemoval = nil
                }
            }
        }
        .alert("MetalOS", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .onKeyPress(.leftArrow) { guard navigationActive else { return .ignored }; navigate("left"); return .handled }
        .onKeyPress(.rightArrow) { guard navigationActive else { return .ignored }; navigate("right"); return .handled }
        .onKeyPress(.upArrow) { guard navigationActive else { return .ignored }; navigate("up"); return .handled }
        .onKeyPress(.downArrow) { guard navigationActive else { return .ignored }; navigate("down"); return .handled }
        .onKeyPress(.return) { guard navigationActive else { return .ignored }; navigate("confirm"); return .handled }
        .onKeyPress(.escape) { guard navigationActive else { return .ignored }; navigate("back"); return .handled }
        .onKeyPress(.space) { guard navigationActive else { return .ignored }; navigate("context"); return .handled }
        .onKeyPress("m") { guard navigationActive else { return .ignored }; navigate("context"); return .handled }
        .onKeyPress("p") { guard navigationActive else { return .ignored }; navigate("home"); return .handled }
        .focusable().focused($libraryFocused).focusEffectDisabled()
        .onChange(of: store.showSettings) { _, open in if !open { libraryFocused = true } }
        .onChange(of: store.showImport) { _, open in if !open { libraryFocused = true } }
        .onChange(of: store.showBuild) { _, open in if !open { libraryFocused = true } }
        .onChange(of: store.console) { _, _ in libraryFocused = true }
        .task(id: store.setupComplete) {
            guard store.setupComplete else { return }
            libraryFocused = true
            controller.action = navigate
            controller.homeAction = { withAnimation(feedback.pageAnimation) { controlCenterOpen.toggle() } }
            controller.priorityAction = { command in
                if store.notice != nil {
                    if ["confirm", "back", "menu", "context"].contains(command) { store.notice = nil }
                    return true
                }
                return handleProfileUpdateToast(command)
            }
            if store.console, let window = NSApp.windows.first, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            store.prepareArtwork()
            await store.scan()
        }
        .onDisappear { controller.action = nil; controller.priorityAction = nil; controller.homeAction = nil }
    }
    @State private var settingsShowTester = false

    private var navigationBar: some View {
        HStack(spacing: 24) {
            Text("METALOS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.1).foregroundStyle(.white.opacity(0.62))
                .padding(.trailing, 8)
            pageTab("Games", selected: !appsPage, slot: 0) { selectPage(apps: false) }
            pageTab("Media", selected: appsPage, slot: 1) { selectPage(apps: true) }
            Spacer(minLength: 16)
            toolbarButton("magnifyingglass", "Search games", slot: 2) { searchOpen = true }
                .keyboardShortcut("f", modifiers: .command)
            toolbarButton("gearshape", "Settings", slot: 3) { store.showSettings = true }
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 34, height: 34)
                .help("User profile · Coming soon")
                .accessibilityLabel("User profile, coming soon")
        }.frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).offset(y: 17) }
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
    private func toolbarButton(_ symbol: String, _ label: String, slot: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 32, height: 34) }
            .buttonStyle(ConsoleButtonStyle()).foregroundStyle(homeRow == 0 && topIndex == slot ? .white : .white.opacity(0.66)).consoleFocus(navigationActive && homeRow == 0 && topIndex == slot, cornerRadius: 9, scale: 1.13).help(label).accessibilityLabel(label)
    }
    private var gameRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    WelcomeTile(selected: welcomeSelected, focused: navigationActive && homeRow == 1 && welcomeSelected) {
                        welcomeSelected = true; addCardSelected = false; libraryFocused = true
                    }
                    ForEach(store.visibleGames) { game in
                        HomeTile(game: game, selected: !welcomeSelected && !addCardSelected && store.selected?.id == game.id,
                                 focused: navigationActive && homeRow == 1 && !welcomeSelected && !addCardSelected && store.selected?.id == game.id,
                                 building: store.builder.isBuilding && store.builder.currentGameID == game.id,
                                 progress: store.builder.progress) {
                            welcomeSelected = false; addCardSelected = false; store.selectedID = game.id; libraryFocused = true
                        }.id(game.id).contextMenu { gameMenu(game) }
                    }
                    AddGameTile(selected: addCardSelected, focused: navigationActive && homeRow == 1 && addCardSelected) {
                        addCardSelected = true; welcomeSelected = false; libraryFocused = true; store.importApp()
                    }
                }.padding(6)
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.23)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }.frame(height: 165)
    }
    private func spotlight(compact: Bool) -> some View {
        Group {
            if let game = store.selected {
                VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                    HStack(spacing: 9) {
                        Image(systemName: game.source.symbol)
                        Text(game.source.rawValue.uppercased()).tracking(3)
                        if game.favorite { Image(systemName: "heart.fill").foregroundStyle(studioAccent) }
                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Text(game.title).font(.system(size: compact ? 43 : 58, weight: .light)).tracking(-1.8)
                        .lineLimit(2).frame(maxWidth: 700, alignment: .leading).id(game.id)
                    Text(game.isAvailable ? (game.launchURL.isEmpty ? "Play starts the first build automatically." : "Your next session is ready.") : "Reconnect this game's drive to play.")
                        .font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.55))
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
                        Button { store.launch(game) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.fill").font(.system(size: 12))
                                Text("Play game").font(.system(size: 15, weight: .semibold))
                            }.foregroundStyle(.white).frame(width: 190, height: 46).background(studioAccent, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 0, cornerRadius: 24, scale: 1.045).disabled(!game.isAvailable)
                        Button { openContext(for: game) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 48, height: 48).background(.white.opacity(0.09), in: Circle())
                        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 1, cornerRadius: 24, scale: 1.045).help("Game options · Menu / Options").accessibilityLabel("Game options")
                        Text(game.isAvailable ? (game.launchURL.isEmpty ? "NOT BUILT" : "BUILT") : "OFFLINE")
                            .font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.35)).padding(.leading, 6)
                    }.padding(.top, 5)
                }.transition(.opacity).animation(.easeOut(duration: 0.25), value: game.id)
            }
        }
    }
    private var gameMetadataPanel: some View {
        Group {
            if let game = store.selected {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ABOUT THIS GAME").font(.system(size: 9, weight: .semibold)).tracking(1.7).foregroundStyle(studioAccent)
                        if let description = game.metadata?.summary ?? game.metadata?.storyline {
                            Text(description).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineSpacing(2).lineLimit(3)
                        } else {
                            Text(store.isFetchingArtwork ? "Finding game details…" : "Game details and screenshots appear here when available.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.48)).lineLimit(2)
                        }
                        let details = [game.metadata?.genres.joined(separator: " · "), game.metadata?.platforms.joined(separator: " · "), game.metadata?.releaseDate]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        if !details.isEmpty { Text(details.joined(separator: "   •   ")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.48)).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let screenshots = game.metadata?.screenshots, !screenshots.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(screenshots.prefix(3)), id: \.path) { shot in
                                if let image = NSImage(contentsOfFile: shot.path) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 148, height: 83)
                                        .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 17).padding(.vertical, 13).frame(height: 122)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
            }
        }
    }
    private func welcomeSpotlight(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                Text("WELCOME TO METALOS").tracking(3)
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            Text("Your game library\nstarts here.")
                .font(.system(size: compact ? 43 : 58, weight: .light)).tracking(-1.8)
                .lineLimit(2).frame(maxWidth: 700, alignment: .leading)
            Text("Choose the + game card to add a Switch title or a Mac app. MetalOS will keep everything ready to play.")
                .font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            Button { store.showImport = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 12))
                    Text("Add a Switch game").font(.system(size: 15, weight: .semibold))
                }.foregroundStyle(.white).frame(width: 210, height: 46).background(studioAccent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(ConsoleButtonStyle()).consoleFocus(navigationActive && homeRow == 2 && actionIndex == 0, cornerRadius: 24, scale: 1.045)
                .padding(.top, 5)
        }.transition(.opacity)
    }
    private var welcomeMetadataPanel: some View {
        HStack(spacing: 12) {
            welcomeDashboardCard(index: 0, eyebrow: "RECENTLY PLAYED", title: recentWelcomeGame?.title ?? "No games played yet", detail: recentWelcomeGame?.lastPlayed?.formatted(.relative(presentation: .named)) ?? "Your next session will show up here", symbol: "clock.arrow.circlepath", game: recentWelcomeGame, accent: Color(red: 0.15, green: 0.43, blue: 0.83)) {
                performWelcomeCard(0)
            }
            welcomeDashboardCard(index: 1, eyebrow: "FAVORITES", title: favoriteWelcomeGame?.title ?? "Your favorites", detail: "\(welcomeGames.filter(\.favorite).count) saved games", symbol: "heart.fill", game: favoriteWelcomeGame, accent: Color(red: 0.36, green: 0.22, blue: 0.67)) {
                performWelcomeCard(1)
            }
            let connected = controller.devices.first
            welcomeDashboardCard(index: 2, eyebrow: "CONTROLLER", title: connected?.name ?? "Ready when you are", detail: connected.map { "\($0.batteryText) battery · \($0.batteryState.title)" } ?? "No controller connected", symbol: connected == nil ? "gamecontroller" : connected!.batterySymbol, game: nil, accent: Color(red: 0.04, green: 0.39, blue: 0.56), value: connected == nil ? "—" : "\(controller.devices.count)") {
                performWelcomeCard(2)
            }
        }
        .frame(height: 112)
        .onAppear { controller.refreshStatus() }
    }
    private func welcomeDashboardCard(index: Int, eyebrow: String, title: String, detail: String, symbol: String, game: Game?, accent: Color, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            welcomeCardIndex = index
            action()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.26))
                    if let game, let path = game.boxArt?.path, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 65, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(.white.opacity(0.88))
                        if let value { Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white).offset(y: 24) }
                    }
                }.frame(width: 65, height: 78).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrow).font(.system(size: 8, weight: .bold)).tracking(1.5).foregroundStyle(studioAccent)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.94)).lineLimit(1)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    if index == 1 {
                        Text("\(welcomeGames.count) GAMES IN LIBRARY").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.38)).padding(.top, 1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [accent.opacity(0.11), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(navigationActive && homeRow == 3 && welcomeCardIndex == index ? 0.26 : 0.08), lineWidth: 1))
            .consoleFocus(navigationActive && homeRow == 3 && welcomeCardIndex == index, cornerRadius: 13, scale: 1.025)
        }
        .buttonStyle(ConsoleButtonStyle())
        .accessibilityLabel("\(eyebrow), \(title). \(detail)")
    }
    private func focusWelcomeGame(_ game: Game) {
        store.selectedID = game.id
        welcomeSelected = false
        addCardSelected = false
        homeRow = 1
    }
    private func performWelcomeCard(_ index: Int) {
        switch index {
        case 0: if let game = recentWelcomeGame { focusWelcomeGame(game) }
        case 1: if let game = favoriteWelcomeGame { focusWelcomeGame(game) }
        case 2: controller.refreshStatus(); showControllerStatus = true
        default: break
        }
    }
    private var appsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Media").font(.system(size: 32, weight: .light))
                    Text("\(store.visibleGames.count)").font(.system(size: 13)).foregroundStyle(studioAccent)
                    Spacer()
                }
                if store.visibleGames.isEmpty { emptyLibrary }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: columns), spacing: 28) {
                    ForEach(store.visibleGames) { game in
                        GameCard(game: game, selected: store.selected?.id == game.id, focused: navigationActive && homeRow == 1,
                                 building: store.builder.isBuilding && store.builder.currentGameID == game.id,
                                 progress: store.builder.progress) { store.selectedID = game.id; libraryFocused = true } launch: { store.launch(game) }
                            .contextMenu { gameMenu(game) }
                    }
                }
            }.padding(.bottom, 28)
        }
    }
    @ViewBuilder private func gameMenu(_ game: Game) -> some View {
        Button("Game options…") { openContext(for: game) }
        Button("Play game") { store.launch(game) }.disabled(!game.isAvailable)
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
            hint("A", appsPage ? "Open app" : "Play game"); hint("X", "Options"); hint("☰", "Options"); hint("PS / P", "Control Center"); hint("LB / RB", "Games / Media"); hint("LB + RB + ☰", "Game Bar")
            Spacer()
            if store.isScanning { ProgressView().controlSize(.mini); Text("Discovering games") }
            else if store.builder.isBuilding { Button("Build in progress") { store.showBuild = true }.buttonStyle(ConsoleButtonStyle()) }
            else { Text("\(store.visibleGames.count) \(appsPage ? "apps" : "games")") }
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
    private enum ContextAction: String {
        case play, favorite, build, remove
        var symbol: String {
            switch self {
            case .play: "play.fill"
            case .favorite: "heart"
            case .build: "hammer"
            case .remove: "minus.circle"
            }
        }
    }
    private func contextActions(for game: Game) -> [ContextAction] {
        var actions: [ContextAction] = [.play, .favorite]
        if game.source == .nxnative { actions.append(.build) }
        actions.append(.remove)
        return actions
    }
    private func contextTitle(_ action: ContextAction, game: Game) -> String {
        switch action {
        case .play: "Play game"
        case .favorite: game.favorite ? "Remove favorite" : "Add to favorites"
        case .build: "Build Studio"
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
                                Text(game.isAvailable ? (game.launchURL.isEmpty ? "PLAY TO PREPARE" : "READY TO PLAY") : "DRIVE OFFLINE")
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
        case .play: store.launch(game)
        case .favorite: store.favorite(game)
        case .build: store.selectedID = game.id; store.showBuild = true
        case .remove: requestRemoval(game)
        }
    }
    private func requestRemoval(_ game: Game) { pendingRemoval = game }
    private func selectPage(apps: Bool) {
        appsPage = apps
        store.showingApps = apps
        store.source = .all
        store.selectedID = store.visibleGames.first?.id
        welcomeSelected = !apps && store.visibleGames.isEmpty
        addCardSelected = false
        homeRow = 0
        topIndex = apps ? 1 : 0
        libraryFocused = true
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
                                    controlCard(1, "Media", "Open your media library", "play.rectangle")
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
            if homeRow == 0 { topIndex = min(max(topIndex + delta, 0), 3) }
            else if homeRow == 2 && !appsPage { actionIndex = min(max(actionIndex + delta, 0), welcomeSelected ? 0 : 1) }
            else if homeRow == 3 && welcomeSelected { welcomeCardIndex = min(max(welcomeCardIndex + delta, 0), 2) }
            else if !appsPage {
                let games = store.visibleGames
                if welcomeSelected {
                    if delta > 0 {
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
            } else { store.moveSelection(delta) }
        case "up":
            if appsPage && homeRow != 0 {
                let index = store.visibleGames.firstIndex { $0.id == store.selected?.id } ?? 0
                if index < columns { homeRow = 0; topIndex = 1 } else { store.moveSelection(-columns) }
            } else { homeRow = max(homeRow - 1, 0) }
        case "down":
            if homeRow == 0 { homeRow = 1 }
            else if appsPage { store.moveSelection(columns) }
            else { homeRow = min(homeRow + 1, welcomeSelected ? 3 : 2) }
        case "confirm":
            if homeRow == 0 {
                switch topIndex {
                case 0: selectPage(apps: false)
                case 1: selectPage(apps: true)
                case 2: searchOpen = true
                case 3: store.showSettings = true
                default: break
                }
            } else if homeRow == 1 && !appsPage {
                if addCardSelected { store.importApp() }
                else if !welcomeSelected, let game = store.selected { store.launch(game) }
            } else if homeRow == 2 && !appsPage {
                if welcomeSelected { store.showImport = true }
                else if let game = store.selected {
                    if actionIndex == 0 { store.launch(game) }
                    else if actionIndex == 1 { openContext(for: game) }
                } else { store.showImport = true }
            } else if homeRow == 3 && welcomeSelected {
                performWelcomeCard(welcomeCardIndex)
            } else if let game = store.selected { store.launch(game) }
            else { store.importApp() }
        case "favorite": if let game = store.selected { store.favorite(game) }
        case "previous":
            selectPage(apps: !appsPage)
        case "next":
            selectPage(apps: !appsPage)
        case "back":
            if searchOpen { searchOpen = false }
            else if homeRow != 1 { homeRow = 1 }
            else if appsPage { selectPage(apps: false) }
            else if store.console { store.toggleConsole() }
        case "menu", "context": if let game = store.selected { openContext(for: game) } else { store.importApp() }
        case "details": if let game = store.selected { openContext(for: game) }
        default: break
        }
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

private struct HomeTile: View {
    let game: Game
    let selected: Bool
    let focused: Bool
    var building = false
    var progress: Double? = nil
    let select: () -> Void
    private var size: CGFloat { selected ? 132 : 92 }
    private var corner: CGFloat { selected ? 17 : 14 }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: corner).fill(.white.opacity(selected ? 0.09 : 0.045))
                    .frame(width: size, height: size)
                    .overlay {
                        GameIcon(game: game, artworkMode: .fill).padding(game.boxArt != nil || game.id.hasPrefix("windows-client:highball:") ? 0 : selected ? 16 : 12)
                    }
                    .overlay(alignment: .bottom) {
                        if building {
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
            }.padding(.top, selected ? 0 : 8).frame(height: 162, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("\(game.title), \(game.source.rawValue)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .animation(ConsoleFeedback.shared.focusAnimation, value: selected)

    }
}
private struct WelcomeTile: View {
    let selected: Bool
    let focused: Bool
    let select: () -> Void
    private var size: CGFloat { selected ? 132 : 92 }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: selected ? 17 : 14)
                        .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.26, blue: 0.58), Color(red: 0.025, green: 0.08, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(studioAccent.opacity(0.22)).frame(width: size * 0.72, height: size * 0.72).blur(radius: 16)
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: selected ? 31 : 23, weight: .ultraLight))
                        if selected { Text("WELCOME").font(.system(size: 8, weight: .bold)).tracking(2) }
                    }.foregroundStyle(.white.opacity(0.86))
                }.frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: selected ? 17 : 14).strokeBorder(.white.opacity(selected ? 0.18 : 0.09)))
                    .consoleFocus(focused, cornerRadius: selected ? 17 : 14, scale: 1.075)
                if selected { Text("Welcome").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading) }
            }.padding(.top, selected ? 0 : 8).frame(height: 162, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Welcome to MetalOS").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
private struct AddGameTile: View {
    let selected: Bool
    let focused: Bool
    let action: () -> Void
    private var size: CGFloat { selected ? 132 : 92 }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: selected ? 17 : 14).fill(.white.opacity(selected ? 0.075 : 0.04))
                    Image(systemName: "plus").font(.system(size: selected ? 31 : 25, weight: .ultraLight)).foregroundStyle(.white.opacity(0.62))
                }.frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: selected ? 17 : 14).strokeBorder(.white.opacity(selected ? 0.16 : 0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .consoleFocus(focused, cornerRadius: selected ? 17 : 14, scale: 1.075)
                if selected { Text("Add game").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: size, alignment: .leading) }
            }.padding(.top, selected ? 0 : 8).frame(height: 162, alignment: .top)
        }.buttonStyle(ConsoleButtonStyle()).help("Add a game or app").accessibilityLabel("Add a game or app").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
private struct HomeBackdrop: View {
    let game: Game?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                studioBackground
                if let game, let path = game.heroArt?.path, let hero = NSImage(contentsOfFile: path) {
                    Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width * 1.04, height: geo.size.height * 1.04).clipped()
                        .blur(radius: 7).opacity(0.72).saturation(0.82)
                        .id(path).transition(.opacity)
                } else if let game {
                    GameIcon(game: game).frame(width: geo.size.width * 0.60, height: geo.size.height * 0.84)
                        .opacity(0.17).blur(radius: 12).rotationEffect(.degrees(-12))
                        .offset(x: geo.size.width * 0.08, y: 30).id(game.id).transition(.opacity)
                }
                RadialGradient(colors: [Color(red: 0.06, green: 0.22, blue: 0.54).opacity(0.44), .clear], center: .init(x: 0.86, y: 0.1), startRadius: 12, endRadius: geo.size.width * 0.72)
                RadialGradient(colors: [studioAccent.opacity(0.12), .clear], center: .init(x: 0.82, y: 0.45), startRadius: 10, endRadius: geo.size.width * 0.65)
                LinearGradient(colors: [studioBackground.opacity(0.32), studioBackground.opacity(0.64)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(stops: [.init(color: studioBackground, location: 0), .init(color: studioBackground.opacity(0.9), location: 0.3), .init(color: studioBackground.opacity(0.2), location: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, studioBackground.opacity(0.95)], startPoint: .center, endPoint: .bottom)
            }.animation(.easeInOut(duration: 0.35), value: game?.id)
                .animation(.easeInOut(duration: 0.35), value: game?.heroArt?.path)
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
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
                        if let url = Bundle.main.url(forResource: "rockstar-games-logo", withExtension: "png"),
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
    let select: () -> Void
    let launch: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.035))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { GameIcon(game: game).padding(game.boxArt != nil || game.id.hasPrefix("windows-client:highball:") ? 0 : 24) }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if game.favorite { Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(studioAccent).padding(7).background(.black.opacity(0.6), in: Circle()) }
                        if !game.isAvailable { Text("OFFLINE").font(.system(size: 9, weight: .bold)).padding(8).background(.black.opacity(0.7), in: Capsule()) }
                    }.padding(10)
                }
                .overlay(alignment: .bottom) {
                    if building {
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
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your controller. Your console.").font(.title.bold())
            Text("D-pad / left stick     Browse Games and Media\nA     Play or open app\nB     Back\nY     Favorite\nPS / P     Control Center\nLB / RB     Switch between Games and Media\nMenu / Options     Game options\nX     Game options\nLB + RB + Menu     In-game Game Bar")
                .lineSpacing(9)
            Text("The overlay offers quick access to your game and library. Games continue running while it is open.").foregroundStyle(.secondary)
            Button("Back to games") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(36).frame(width: 580)
            .consoleInput { command in
                if command == "back" || command == "menu" || command == "context" { dismiss() }
            }
    }
}
