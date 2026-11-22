import SwiftUI

struct ConsoleGameDetail: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var runtimes = ConsoleGameRuntimes.shared
    @ObservedObject private var guide = GameOverlayController.shared
    let game: Game
    let onClose: () -> Void
    let onAction: (GameDetailAction) -> Void

    private enum Target: Hashable {
        case back, play, favorite, state(String), setting(ConsoleRuntimeSetting)
        case dev, libraryAction(GameDetailAction), option(String)
    }

    @FocusState private var focus: Target?
    @State private var openSetting: ConsoleRuntimeSetting?
    @State private var showDev = false
    @State private var showBottleTools = false
    @State private var states: [ConsoleSaveState] = []
    @State private var loadingStates = false
    @State private var working = false
    @State private var launchTask: Task<Void, Never>?
    @State private var rememberedFocus: Target?
    @State private var readGeneration = 0
    @State private var status: String?
    @State private var ps2Build: String?

    private var runtime: ConsoleGameRuntime? { runtimes.providers[game.source] }
    private var cover: ConsoleHomeGame {
        ConsoleHomeGame(game, windowsDefault: store.data.settings.defaultWindowsRuntime)
    }
    private var canPlay: Bool { game.isAvailable || game.windowsBottlePath != nil }
    private var usesWindowsRuntime: Bool {
        game.windowsExecutablePath != nil || game.windowsBottlePath != nil || game.windowsStoreProvider != nil
            || URL(string: game.launchURL)?.scheme == "metalos-windows"
    }
    private var extraActions: [GameDetailAction] {
        GameDetailsView.actions(for: game).filter { $0 != .play && $0 != .favorite }
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 1200 ? 32 : ConsoleDesign.Space.screenInset
            ZStack {
                ConsoleHomeBackdrop(paths: cover.heroPaths, video: nil, accent: appearance.accent)
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let openSetting, let options = options(for: openSetting) {
                        optionSheet(openSetting, options: options)
                    } else {
                        detailContent
                    }
                    footer
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 22)
            }
        }
        .foregroundStyle(ConsoleDesign.Palette.text)
        .preferredColorScheme(.dark)
        .consoleNavigation { command in
            navigation.handle(command, focus: $focus, activate: activate, perform: handleShortcut)
        }
        .task(id: game.id) {
            focus = entry
            ps2Build = nil
            if game.source == .ps2, let workspace = store.workspaceURL {
                ps2Build = (try? String(contentsOf: PS2RuntimeLayout.versionFile(in: workspace), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onReceive(runtimes.$providers.dropFirst()) { _ in
            readGeneration &+= 1
        }
        .task(id: readGeneration) { await reloadStates() }
        .onDisappear { launchTask?.cancel() }
        .onChange(of: focus) { _, next in if let next { rememberedFocus = next } }
        .onChange(of: guide.isVisible) { _, open in
            if !open { focus = navigation.restoredFocus(rememberedFocus) }
        }
        .consolePage(isPresented: $showBottleTools, onDismiss: { focus = .libraryAction(.bottleTools) }) {
            if let workspace = store.workspaceURL {
                WindowsBottleToolsView(game: game, workspace: workspace, onClose: { showBottleTools = false })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            action(.back, "Games", "chevron.left")
            Spacer()
            if let status {
                Text(status).font(ConsoleDesign.Typography.metadata).foregroundStyle(ConsoleDesign.Palette.secondaryText)
                    .lineLimit(2).accessibilityLabel(status)
            }
            if working { ProgressView().controlSize(.small) }
        }
    }

    private var detailContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ConsoleDesign.Space.gutter) {
                    hero.id("hero")
                    saves
                    launchSettings
                    developer
                    libraryActions
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus) { _, target in
                guard let target else { return }
                withAnimation(feedback.pageAnimation) {
                    switch target {
                    case .back, .play, .favorite: proxy.scrollTo("hero", anchor: .top)
                    case .state: proxy.scrollTo("saves", anchor: .center)
                    default: proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .onChange(of: showDev) { _, expanded in
                if expanded { withAnimation(feedback.pageAnimation) { proxy.scrollTo("dev-details", anchor: .bottom) } }
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(game.title).font(ConsoleDesign.Typography.display).lineLimit(2).minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Text(cover.badges.joined(separator: "  ·  ")).font(ConsoleDesign.Typography.metadata)
                    .foregroundStyle(ConsoleDesign.Palette.secondaryText)
                HStack(spacing: 24) {
                    stat("Playtime", game.playedSeconds.map { GameBarFormatting.duration($0) } ?? "—")
                    stat("Last played", game.lastPlayed?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                }
                HStack(spacing: 12) {
                    if canPlay {
                        action(.play, game.windowsBottlePath != nil && game.windowsExecutablePath == nil ? "Choose Executable" : "Play",
                               "play.fill", prominent: true)
                    }
                    action(.favorite, game.favorite ? "Favorited" : "Favorite", game.favorite ? "heart.fill" : "heart")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !cover.heroPaths.isEmpty {
                ConsoleHomeArtwork(paths: cover.heroPaths, maxPixelSize: 1200)
                    .frame(maxWidth: 510)
                    .aspectRatio(2.3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.Radius.card, style: .continuous))
            }
        }
    }

    private var saves: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Save States")
            if states.isEmpty {
                ConsoleCard {
                    Label(saveStatus, systemImage: "archivebox")
                        .font(ConsoleDesign.Typography.action)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(states) { state in stateCard(state).id(state.id) }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: focus) { _, target in
                        if case .state(let id) = target {
                            withAnimation(feedback.pageAnimation) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .id("saves")
    }

    private var saveStatus: String {
        if loadingStates { return "Reading save states…" }
        if runtime?.states == nil { return "Save states are managed by this game or its runtime." }
        return "No save states yet"
    }

    private func stateCard(_ state: ConsoleSaveState) -> some View {
        let target = Target.state(state.id)
        return Button { activate(target) } label: {
            ConsoleCard(padding: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        ConsoleDesign.Palette.canvas
                        Image(systemName: "archivebox").foregroundStyle(.secondary)
                        ConsoleHomeArtwork(paths: state.screenshotPath.map { [$0] } ?? [], maxPixelSize: 480)
                    }
                    .frame(height: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(state.title).font(ConsoleDesign.Typography.action).lineLimit(1)
                    Text(state.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(ConsoleDesign.Typography.metadata).foregroundStyle(ConsoleDesign.Palette.secondaryText)
                }
                .padding(12)
                .frame(width: 218, alignment: .leading)
            }
        }
        .buttonStyle(ConsoleButtonStyle())
        .focusable(runtime?.launchState != nil)
        .focused($focus, equals: target)
        .focusEffectDisabled()
        .consoleFocusEffect(focus == target, accent: appearance.accent)
        .disabled(runtime?.launchState == nil || working)
    }

    private var launchSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Launch Settings")
            ForEach(ConsoleRuntimeSetting.allCases) { setting in
                if let options = options(for: setting), !options.values.isEmpty {
                    let value = options.values.first { $0.id == options.selectedID }?.title ?? "Choose"
                    FocusableButton(id: Target.setting(setting), focus: $focus, accent: appearance.accent,
                                    action: { activate(.setting(setting)) }) {
                        settingLabel(setting, value: value, selectable: true)
                    }
                    .id(Target.setting(setting))
                } else if setting != .metalHUD {
                    ConsoleCard(cornerRadius: ConsoleDesign.Radius.control, padding: 16) {
                        settingLabel(setting, value: unavailableValue(setting), selectable: false)
                    }
                }
            }
        }
    }

    private func settingLabel(_ setting: ConsoleRuntimeSetting, value: String, selectable: Bool) -> some View {
        HStack(spacing: 12) {
            Text(setting.rawValue).font(ConsoleDesign.Typography.action)
            Spacer()
            Text(value).font(ConsoleDesign.Typography.metadata)
                .foregroundStyle(ConsoleDesign.Palette.secondaryText)
            if selectable { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusableButton(id: Target.dev, focus: $focus, accent: appearance.accent, action: { activate(.dev) }) {
                Label("Developer Info", systemImage: showDev ? "chevron.up" : "chevron.down")
            }
            .id(Target.dev)
            if showDev {
                ConsoleCard {
                    VStack(alignment: .leading, spacing: 12) {
                        stat("File path", game.installPath)
                        stat("Core build", build)
                        stat("Metal pipeline", runtime?.pipeline?(game) ?? "Runtime has not reported a pipeline")
                        if let id = game.titleID { stat("Title ID", id) }
                        if let match = game.artworkMatchedTitle { stat("Artwork match", match) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id("dev-details")
                .transition(.opacity)
            }
        }
    }

    private var libraryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = game.metadata?.summary ?? game.metadata?.storyline, !description.isEmpty {
                heading("About")
                Text(description).font(ConsoleDesign.Typography.body)
                    .foregroundStyle(ConsoleDesign.Palette.secondaryText)
            }
            HStack(spacing: 10) {
                ForEach(extraActions) { item in
                    action(.libraryAction(item), item.title(for: game), item.symbol).id(Target.libraryAction(item))
                }
            }
        }
    }

    private func optionSheet(_ setting: ConsoleRuntimeSetting, options: ConsoleRuntimeOptions) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heading(setting.rawValue)
                    if setting == .controller, runtime?.options?(game, setting) == nil {
                        Text("Applies to the MetalOS Guide. Gameplay controls are managed by the game or macOS.")
                            .font(ConsoleDesign.Typography.body).foregroundStyle(ConsoleDesign.Palette.secondaryText)
                    }
                    ForEach(options.values) { option in
                        FocusableButton(id: Target.option(option.id), focus: $focus, accent: appearance.accent,
                                        action: { activate(.option(option.id)) }) {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if option.id == options.selectedID { Image(systemName: "checkmark.circle.fill") }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .id(Target.option(option.id))
                        .accessibilityAddTraits(option.id == options.selectedID ? [.isSelected] : [])
                    }
                }
                .padding(8)
            }
            .onChange(of: focus) { _, target in
                if let target, case .option = target { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Label("Navigate", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            HStack { ConsolePromptGlyph(control: .confirm, fallbackLabel: "↵"); Text("Select") }
            HStack { ConsolePromptGlyph(control: .back, fallbackLabel: "Esc"); Text("Back") }
            Spacer()
        }
        .font(ConsoleDesign.Typography.metadata)
        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(ConsoleDesign.Palette.border).frame(height: 1) }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(ConsoleDesign.Typography.heading).accessibilityAddTraits(.isHeader)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 15)).foregroundStyle(ConsoleDesign.Palette.secondaryText)
            Text(value).font(ConsoleDesign.Typography.metadata).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func action(_ id: Target, _ title: String, _ symbol: String, prominent: Bool = false) -> some View {
        FocusableButton(id: id, focus: $focus, accent: appearance.accent, prominent: prominent,
                        action: { activate(id) }) {
            Label(title, systemImage: symbol)
        }
    }

    private var build: String {
        if let value = runtime?.build?(game) { return value }
        if game.source == .ps2, let ps2Build, !ps2Build.isEmpty { return ps2Build }
        if let revision = game.builtNXProfileRevision { return "NXNative profile \(revision)" }
        return "Not reported"
    }

    private func unavailableValue(_ setting: ConsoleRuntimeSetting) -> String {
        switch setting {
        case .core: cover.badges.last ?? game.source.rawValue
        case .graphics where usesWindowsRuntime: "Managed by D3DMetal"
        default: "Managed by game or runtime"
        }
    }

    private func options(for setting: ConsoleRuntimeSetting) -> ConsoleRuntimeOptions? {
        if let supplied = runtime?.options?(game, setting) { return supplied }
        switch setting {
        case .core where usesWindowsRuntime:
            return .init(
                values: [.init(id: "default", title: "Use PC Default")] + WindowsCompatibilityRuntime.allCases.map {
                    .init(id: $0.rawValue, title: $0.title)
                },
                selectedID: game.windowsCompatibilityRuntime?.rawValue ?? "default"
            ) { id in
                store.setWindowsCompatibilityRuntime(WindowsCompatibilityRuntime(rawValue: id), for: game.id)
            }
        case .graphics where usesWindowsRuntime && store.effectiveWindowsRuntime(for: game) != .gamePortingToolkit:
            let backend = game.windowsGraphicsBackendUserSet == true
                ? game.windowsGraphicsBackend ?? .automatic
                : game.lutrisWineProfile?.preferredGraphicsBackend ?? .automatic
            return .init(values: WindowsGraphicsBackend.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                         selectedID: backend.rawValue) { id in
                if let value = WindowsGraphicsBackend(rawValue: id) { store.setWindowsGraphicsBackend(value, for: game.id) }
            }
        case .controller:
            return .init(values: ConsoleGuideProfile.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                         selectedID: (game.guideProfile ?? .southConfirm).rawValue) { id in
                if let profile = ConsoleGuideProfile(rawValue: id) { store.setGuideProfile(profile, gameID: game.id) }
            }
        case .metalHUD where game.source == .nxnative:
            return .init(
                values: [.init(id: "off", title: "Off"), .init(id: "on", title: "On")],
                selectedID: game.metalHUDEnabled == true ? "on" : "off"
            ) { id in
                store.setMetalHUD(id == "on", gameID: game.id)
            }
        default: return nil
        }
    }

    private var entry: Target { canPlay ? .play : .favorite }

    private var navigation: GamepadNavigationManager<Target> {
        let rows: [[Target]]
        if let openSetting, let options = options(for: openSetting) {
            rows = [[.back]] + options.values.map { [.option($0.id)] }
        } else {
            var content: [[Target]] = [[.back], canPlay ? [.play, .favorite] : [.favorite]]
            if runtime?.launchState != nil, !states.isEmpty { content.append(states.map { .state($0.id) }) }
            content += ConsoleRuntimeSetting.allCases.compactMap { setting in
                guard let options = options(for: setting), !options.values.isEmpty else { return nil }
                return [.setting(setting)]
            }
            content.append([.dev])
            if !extraActions.isEmpty { content.append(extraActions.map { .libraryAction($0) }) }
            rows = content
        }
        return .init(entry: openSetting == nil ? entry : rows.dropFirst().first?.first,
                     enabled: Set(rows.flatMap { $0 }), neighbors: consoleGridNeighbors(rows))
    }

    private func activate(_ target: Target) {
        guard !working else { return }
        switch target {
        case .back: back()
        case .play: onAction(.play)
        case .favorite: onAction(.favorite)
        case .state(let id):
            guard let load = runtime?.launchState, let state = states.first(where: { $0.id == id }) else { return }
            working = true
            launchTask = Task { @MainActor in
                defer { working = false; launchTask = nil }
                do {
                    try await load(game, state)
                    if !Task.isCancelled { onClose() }
                } catch {
                    if !Task.isCancelled { status = error.localizedDescription }
                }
            }
        case .setting(let setting):
            guard let options = options(for: setting), let first = options.values.first else { return }
            openSetting = setting
            focus = .option(options.selectedID ?? first.id)
        case .option(let id):
            guard let setting = openSetting, let choices = options(for: setting),
                  choices.values.contains(where: { $0.id == id }) else { return }
            do { try choices.apply(id); status = nil; back() }
            catch { status = error.localizedDescription }
        case .dev: withAnimation(feedback.pageAnimation) { showDev.toggle() }
        case .libraryAction(.bottleTools):
            if store.workspaceURL != nil { showBottleTools = true }
            else { status = "Choose a library folder to open the Windows bottle." }
        case .libraryAction(let action): onAction(action)
        }
    }

    private func handleShortcut(_ command: ConsoleCommand) {
        switch command {
        case .back: back()
        case .secondary where openSetting == nil: activate(.favorite)
        case .guide: GameOverlayController.shared.toggle()
        default: break
        }
    }

    private func back() {
        guard !working else { return }
        if let previous = openSetting {
            openSetting = nil
            focus = .setting(previous)
        } else {
            onClose()
        }
    }

    private func reloadStates() async {
        guard let read = runtime?.states else { states = []; return }
        loadingStates = true
        defer { if !Task.isCancelled { loadingStates = false } }
        do {
            let available = try await read(game)
            guard !Task.isCancelled else { return }
            states = available.sorted { $0.savedAt > $1.savedAt }
        } catch {
            if !Task.isCancelled { status = error.localizedDescription }
        }
    }
}

/// Builds directional links for rows with different numbers of controls.
func consoleGridNeighbors<ID: Hashable>(_ rows: [[ID]]) -> [ID: [ConsoleDirection: ID]] {
    var graph: [ID: [ConsoleDirection: ID]] = [:]
    for (rowIndex, row) in rows.enumerated() {
        for (column, id) in row.enumerated() {
            var links: [ConsoleDirection: ID] = [:]
            if column > 0 { links[.left] = row[column - 1] }
            if column + 1 < row.count { links[.right] = row[column + 1] }
            if rowIndex > 0 {
                let above = rows[rowIndex - 1]
                if !above.isEmpty { links[.up] = above[min(column, above.count - 1)] }
            }
            if rowIndex + 1 < rows.count {
                let below = rows[rowIndex + 1]
                if !below.isEmpty { links[.down] = below[min(column, below.count - 1)] }
            }
            graph[id] = links
        }
    }
    return graph
}
