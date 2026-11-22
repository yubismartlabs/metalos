import SwiftUI

enum ConsoleHomeTab: String, CaseIterable {
    case games = "Games"
    case cores = "Cores"
    case updates = "Updates"
    case customize = "Customize"
    case settings = "Settings"

    func offset(by amount: Int) -> Self {
        let tabs = Self.allCases
        let index = tabs.firstIndex(of: self) ?? 0
        return tabs[(index + amount + tabs.count) % tabs.count]
    }

    var symbol: String {
        switch self {
        case .games: "gamecontroller"
        case .cores: "square.stack.3d.up"
        case .updates: "arrow.down.circle"
        case .customize: "paintbrush"
        case .settings: "gearshape"
        }
    }

    var actionTitle: String {
        switch self {
        case .games: "Add Game"
        case .cores: "PlayStation 2 Core"
        case .updates: "System Software"
        case .customize: "Wallpaper & Display"
        case .settings: "Open Settings"
        }
    }
}

struct ConsoleHomeGame: Identifiable {
    let id: String
    let title: String
    let badges: [String]
    let symbol: String
    let tilePaths: [String]
    let heroPaths: [String]
    let lastPlayed: Date?
    let playedSeconds: TimeInterval?
    var canPlay = true

    init(
        id: String, title: String, badges: [String], symbol: String,
        tilePaths: [String], heroPaths: [String], lastPlayed: Date?,
        playedSeconds: TimeInterval?, canPlay: Bool = true
    ) {
        self.id = id
        self.title = title
        self.badges = badges
        self.symbol = symbol
        self.tilePaths = tilePaths
        self.heroPaths = heroPaths
        self.lastPlayed = lastPlayed
        self.playedSeconds = playedSeconds
        self.canPlay = canPlay
    }

    init(_ game: Game, windowsDefault: WindowsCompatibilityRuntime? = nil) {
        let badges: [String]
        switch game.source {
        case .nxnative: badges = ["Nintendo Switch", "NXNative"]
        case .ps2: badges = ["PS2", "ARMSX2"]
        case .windows:
            let backend = game.windowsGraphicsBackend ?? .automatic
            let runtime = game.windowsCompatibilityRuntime ?? windowsDefault ?? .managedWine
            badges = ["Windows", runtime == .gamePortingToolkit ? "D3DMetal" : backend.title]
        default: badges = [game.source.rawValue]
        }
        let tiles = [game.tileArt?.path, game.boxArt?.path, game.artworkPath, game.heroArt?.path]
            .compactMap { $0 }
        self.init(
            id: game.id, title: game.title, badges: badges, symbol: game.source.symbol,
            tilePaths: tiles, heroPaths: [game.heroArt?.path].compactMap { $0 } + tiles,
            lastPlayed: game.lastPlayed, playedSeconds: game.playedSeconds,
            canPlay: game.isAvailable && (game.windowsBottlePath == nil || game.windowsExecutablePath != nil)
        )
    }
}

enum ConsoleHomeAction {
    case play(String), gameHub(String), addGame, openTab(ConsoleHomeTab)
    case accessories, exitConsole, guide
}

private enum ConsoleHomeFocus: Hashable {
    case profile, tab(ConsoleHomeTab), game(String), addGame, play, gameHub, tabAction, accessories, exit
}

struct ConsoleHomeHub<Status: View>: View {
    let games: [ConsoleHomeGame]
    let wallpaperPaths: [String]
    var wallpaperVideo: URL?
    let accent: Color
    @Binding var tab: ConsoleHomeTab
    @Binding var selectedID: String?
    let onAction: (ConsoleHomeAction) -> Void
    @ViewBuilder var status: () -> Status

    @State private var showingProfile = false
    @FocusState private var focused: ConsoleHomeFocus?
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var preferences = ConsolePreferences.shared
    @ObservedObject private var overlay = GameOverlayController.shared

    private var game: ConsoleHomeGame? {
        games.first { $0.id == selectedID } ?? games.first
    }

    private var showingGames: Bool { tab == .games && !showingProfile }

    private var entry: ConsoleHomeFocus {
        if showingProfile { return .accessories }
        if !showingGames { return .tabAction }
        return game.map { .game($0.id) } ?? .addGame
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 1200 ? 32 : ConsoleDesign.Space.screenInset
            let compact = geometry.size.height < 800
            let artPaths = showingGames ? game?.heroPaths ?? [] : []
            ZStack {
                ConsoleHomeBackdrop(paths: artPaths + wallpaperPaths,
                                    video: showingGames && artPaths.isEmpty ? wallpaperVideo : nil,
                                    accent: accent)
                VStack(alignment: .leading, spacing: compact ? 12 : 24) {
                    header
                    if showingGames {
                        if let game {
                            rail(height: preferences.density.tileHeight(compactWindow: compact),
                                 viewportWidth: geometry.size.width - inset * 2 + 24)
                            hero(game, compact: compact)
                        } else {
                            destination("Your games", symbol: "gamecontroller", detail: "Import a game to start playing.", target: .addGame)
                        }
                    } else if showingProfile {
                        profile
                    } else {
                        destination(tab.rawValue, symbol: tab.symbol, detail: nil, target: .tabAction)
                    }
                    ConsoleHomePromptBar(
                        confirmTitle: confirmTitle,
                        showsGameOptions: showingGames && game != nil,
                        backTitle: showingGames ? "Exit Console" : "Games"
                    )
                }
                .padding(.horizontal, inset)
                .padding(.vertical, compact ? 16 : 28)
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(ConsoleDesign.Palette.text)
        .consoleNavigation { command in
            navigation.handle(command, focus: $focused, activate: activate, perform: perform)
        }
        .task { focused = entry }
        .onChange(of: focused) { _, focus in
            if case .game(let id) = focus { selectedID = id }
        }
        .onChange(of: games.map(\.id)) { previous, _ in
            if showingGames, previous.isEmpty || !navigation.enabled.contains(focused ?? .tabAction) {
                focused = entry
            }
        }
        .onChange(of: game?.canPlay) { _, _ in
            if focused == .play, game?.canPlay != true { focused = game == nil ? entry : .gameHub }
        }
        .onChange(of: overlay.isVisible) { _, open in
            if !open { focused = navigation.restoredFocus(focused) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FocusableButton(id: .profile, focus: $focused, isScopeActive: !overlay.isVisible, accent: accent,
                            horizontalPadding: 12, action: { activate(.profile) }) {
                Label("Player 1", systemImage: "person.crop.circle").fixedSize()
            }
            .accessibilityLabel("Player 1 profile")

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                ForEach(ConsoleHomeTab.allCases, id: \.self) { candidate in
                    let selected = !showingProfile && tab == candidate
                    Button { activate(.tab(candidate)) } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 17, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? ConsoleDesign.Palette.text : ConsoleDesign.Palette.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: ConsoleDesign.Space.minimumControlHeight)
                            .background(alignment: .bottom) {
                                if selected {
                                    Capsule().fill(accent).frame(width: 24, height: 3).padding(.bottom, 5)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ConsoleButtonStyle())
                    .focusable()
                    .focused($focused, equals: .tab(candidate))
                    .focusEffectDisabled()
                    .consoleFocusEffect(focused == .tab(candidate) && !overlay.isVisible, accent: accent)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ConsoleDesign.Palette.border).allowsHitTesting(false) }

            Spacer(minLength: 0)
            status()
        }
    }

    private func rail(height: CGFloat, viewportWidth: CGFloat) -> some View {
        let space = "console.gameRail"
        let width = height * 1.63
        return VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(ConsoleDesign.Typography.heading)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: preferences.density.spacing) {
                        ForEach(games) { item in
                            let id = ConsoleHomeFocus.game(item.id)
                            Button { select(item.id) } label: {
                                ConsoleHomeTile(game: item, width: width, height: height,
                                                viewportWidth: viewportWidth, coordinateSpace: space)
                            }
                            .buttonStyle(ConsoleButtonStyle())
                            .focusable()
                            .focused($focused, equals: id)
                            .focusEffectDisabled()
                            .consoleFocusEffect(focused == id && !overlay.isVisible,
                                                cornerRadius: ConsoleDesign.Radius.card, accent: accent)
                            .accessibilityLabel(item.title)
                            .accessibilityAddTraits(item.id == game?.id ? [.isSelected] : [])
                            .id(id)
                        }
                        if !games.isEmpty {
                            FocusableButton(id: .addGame, focus: $focused, accent: accent,
                                            action: { onAction(.addGame) }) {
                                Label("Add Game", systemImage: "plus")
                            }
                            .id(ConsoleHomeFocus.addGame)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .coordinateSpace(name: space)
                .frame(height: height + 24)
                .scrollIndicators(.hidden)
                .onChange(of: focused, initial: true) { _, value in
                    guard let value else { return }
                    switch value {
                    case .game, .addGame:
                        withAnimation(feedback.pageAnimation) { proxy.scrollTo(value, anchor: .center) }
                    default: break
                    }
                }
            }
            .padding(.horizontal, -12)
        }
    }

    private func hero(_ game: ConsoleHomeGame, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: ConsoleDesign.Space.section) {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                Text(game.title)
                    .font(compact ? ConsoleDesign.Typography.title : ConsoleDesign.Typography.display)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: ConsoleDesign.Space.badge) {
                    ForEach(game.badges, id: \.self) { badge in
                        Text(badge)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: ConsoleDesign.Radius.badge))
                    }
                }
                .font(ConsoleDesign.Typography.metadata)
                HStack(spacing: ConsoleDesign.Space.gutter) {
                    stat("Playtime", value: game.playedSeconds.map(Self.playtime) ?? "—")
                    stat("Last played", value: game.lastPlayed?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                }
                HStack(spacing: ConsoleDesign.Space.related) {
                    FocusableButton(id: .play, focus: $focused, accent: accent,
                                    prominent: true, action: { activate(.play) }) {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(!game.canPlay)
                    FocusableButton(id: .gameHub, focus: $focused, accent: accent, action: { activate(.gameHub) }) {
                        Label("Game Hub", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                ConsoleDesign.Palette.panel
                Image(systemName: game.symbol)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.32))
                ConsoleHomeArtwork(paths: game.heroPaths, maxPixelSize: 1600)
            }
            .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.Radius.overlay, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: ConsoleDesign.Radius.overlay, style: .continuous)
                    .strokeBorder(.white.opacity(0.18)) }
            .frame(maxWidth: 760, maxHeight: 420)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15)).foregroundStyle(ConsoleDesign.Palette.secondaryText)
            Text(value).font(ConsoleDesign.Typography.metadata)
        }
        .accessibilityElement(children: .combine)
    }

    private func destination(_ title: String, symbol: String, detail: String?, target: ConsoleHomeFocus) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title).font(ConsoleDesign.Typography.display).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(ConsoleDesign.Typography.body).foregroundStyle(ConsoleDesign.Palette.secondaryText)
            }
            FocusableButton(id: target, focus: $focused, accent: accent, action: { activate(target) }) {
                Label(target == .addGame ? "Add Game" : tab.actionTitle, systemImage: "arrow.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Player 1").font(ConsoleDesign.Typography.display).accessibilityAddTraits(.isHeader)
            HStack(spacing: ConsoleDesign.Space.related) {
                FocusableButton(id: .accessories, focus: $focused, accent: accent, action: { activate(.accessories) }) {
                    Label("Controllers", systemImage: "gamecontroller")
                }
                FocusableButton(id: .exit, focus: $focused, accent: accent, action: { activate(.exit) }) {
                    Label("Exit Console Mode", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var confirmTitle: String {
        switch focused {
        case .play: "Play"
        case .game: game?.canPlay == true ? "Play" : "Game Hub"
        case .gameHub: "Game Hub"
        case .addGame: "Add Game"
        case .tabAction: tab.actionTitle
        case .exit: "Exit Console"
        default: "Select"
        }
    }

    private var navigation: GamepadNavigationManager<ConsoleHomeFocus> {
        let headers: [ConsoleHomeFocus] = [.profile] + ConsoleHomeTab.allCases.map { .tab($0) }
        var neighbors = horizontal(headers)
        for header in headers { neighbors[header, default: [:]][.down] = entry }
        let up: ConsoleHomeFocus = showingProfile ? .profile : .tab(tab)

        if showingGames {
            let rail = games.map { ConsoleHomeFocus.game($0.id) } + [.addGame]
            neighbors.merge(horizontal(rail)) { current, _ in current }
            for item in rail { neighbors[item, default: [:]][.up] = up }
            if let game {
                let actions: [ConsoleHomeFocus] = game.canPlay ? [.play, .gameHub] : [.gameHub]
                neighbors.merge(horizontal(actions)) { current, _ in current }
                for item in rail where item != .addGame { neighbors[item, default: [:]][.down] = actions.first }
                neighbors[.addGame, default: [:]][.down] = .gameHub
                for action in actions { neighbors[action, default: [:]][.up] = .game(game.id) }
            }
        } else if showingProfile {
            neighbors[.accessories] = [.right: .exit, .up: up]
            neighbors[.exit] = [.left: .accessories, .up: up]
        } else {
            neighbors[.tabAction] = [.up: up]
        }

        return GamepadNavigationManager(entry: entry, enabled: Set(neighbors.keys), neighbors: neighbors)
    }

    private func horizontal(_ items: [ConsoleHomeFocus]) -> [ConsoleHomeFocus: [ConsoleDirection: ConsoleHomeFocus]] {
        var neighbors: [ConsoleHomeFocus: [ConsoleDirection: ConsoleHomeFocus]] = [:]
        for (index, item) in items.enumerated() {
            var links: [ConsoleDirection: ConsoleHomeFocus] = [:]
            if index > 0 { links[.left] = items[index - 1] }
            if index + 1 < items.count { links[.right] = items[index + 1] }
            neighbors[item] = links
        }
        return neighbors
    }

    private func select(_ id: String) {
        selectedID = id
        focused = .game(id)
    }

    private func selectTab(_ destination: ConsoleHomeTab, headerFocus: Bool) {
        showingProfile = false
        tab = destination
        focused = headerFocus ? .tab(destination) : entry
    }

    private func activate(_ target: ConsoleHomeFocus) {
        switch target {
        case .profile:
            showingProfile = true
            focused = .accessories
        case .tab(let destination): selectTab(destination, headerFocus: true)
        case .game(let id):
            select(id)
            if games.first(where: { $0.id == id })?.canPlay == true { onAction(.play(id)) }
            else { onAction(.gameHub(id)) }
        case .play:
            if let game, game.canPlay { onAction(.play(game.id)) }
        case .gameHub:
            if let game { onAction(.gameHub(game.id)) }
        case .addGame: onAction(.addGame)
        case .tabAction: onAction(.openTab(tab))
        case .accessories: onAction(.accessories)
        case .exit: onAction(.exitConsole)
        }
    }

    private func perform(_ command: ConsoleCommand) {
        switch command {
        case .previousTab: selectTab(tab.offset(by: -1), headerFocus: false)
        case .nextTab: selectTab(tab.offset(by: 1), headerFocus: false)
        case .secondary, .details, .menu, .context:
            if showingGames, let game { onAction(.gameHub(game.id)) }
        case .back:
            if showingGames { onAction(.exitConsole) }
            else { selectTab(.games, headerFocus: false) }
        case .guide: onAction(.guide)
        case .confirm, .move: break
        }
    }

    private static func playtime(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1 min" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

private struct ConsoleHomeTile: View {
    let game: ConsoleHomeGame
    let width: CGFloat
    let height: CGFloat
    let viewportWidth: CGFloat
    let coordinateSpace: String
    @State private var nearViewport = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ConsoleDesign.Palette.panel
            Image(systemName: game.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if nearViewport { ConsoleHomeArtwork(paths: game.tilePaths, maxPixelSize: 560) }
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            Text(game.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ConsoleDesign.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.18)) }
        .onGeometryChange(for: Bool.self) { geometry in
            let position = geometry.frame(in: .named(coordinateSpace))
            return position.maxX > -width && position.minX < viewportWidth + width
        } action: { nearViewport = $0 }
    }
}
