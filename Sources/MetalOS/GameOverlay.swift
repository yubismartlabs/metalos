import SwiftUI
import AppKit
import Combine

/// Determines ownership from an installed payload, never from the last activated app alone.
struct OverlayApplicationPolicy {
    static func permitsQuit(source: GameSource) -> Bool {
        [.native, .appStore, .nxnative, .ps2].contains(source)
    }
    static func matches(installPath: String, bundleURL: URL?, executableURL: URL?, bundleIdentifier: String?) -> Bool {
        let managers = GameDiscovery.managerBundleIDs.union(["com.valvesoftware.steam", "com.heroicgameslauncher.hgl", "com.codeweavers.CrossOver", "com.apple.finder"])
        guard !installPath.isEmpty, !managers.contains(bundleIdentifier ?? "") else { return false }
        let root = URL(fileURLWithPath: installPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard root != "/" else { return false }
        return [bundleURL, executableURL].compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath().path }.contains {
            $0 == root || $0.hasPrefix(root + "/")
        }
    }
}

private enum OverlayAction: String, Identifiable {
    case resume, quickSave, quickLoad, performance, remap, capture, home, console, favorite
    case bottomConfirms, rightConfirms, backToGuide

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .resume: "play.fill"
        case .quickSave: "arrow.down.to.line"
        case .quickLoad: "arrow.up.to.line"
        case .performance: "speedometer"
        case .remap: "gamecontroller"
        case .capture: "camera.fill"
        case .home: "house"
        case .console: "terminal.fill"
        case .favorite: "heart.fill"
        case .bottomConfirms, .rightConfirms: "button.programmable"
        case .backToGuide: "chevron.left"
        }
    }
}

/// A separate native panel. The game continues running underneath it.
@MainActor
final class GameOverlayController: ObservableObject {
    static let shared = GameOverlayController()
    @Published private(set) var isVisible = false
    @Published private(set) var game: Game?
    @Published fileprivate var selection = 0
    @Published fileprivate var message: String?
    @Published fileprivate var sessionStarted: Date?
    @Published fileprivate var sample: GameProcessSample?
    @Published fileprivate var showingConsole = false
    @Published fileprivate var showingRemap = false
    @Published fileprivate var hudEnabled = false
    @Published fileprivate var frames: ConsoleFrameMetrics?
    @Published fileprivate var busy = false
    private weak var store: LibraryStore?
    private var gameApplication: NSRunningApplication?
    private var managedPID: pid_t?
    private var hudPanel: NSPanel?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var playtimeStarted: TimeInterval?
    private var previousApplication: NSRunningApplication?
    private var panel: OverlayPanel?
    private var observers: [NSObjectProtocol] = []
    private var keyboardMonitor: Any?
    private var observation: AnyCancellable?
    private var sampler = GameProcessSampler()
    private var sampleTimer: Timer?

    func configure(store: LibraryStore) {
        self.store = store
        GameFullScreenEnforcer.shared.configure(store: store)
        let controller = ControllerManager.shared
        controller.overlayAction = { [weak self] in self?.toggle() }
        controller.canToggleOverlay = { [weak self] in self?.canToggle ?? false }
        controller.overlayRoute = { [weak self] command in self?.route(command) ?? false }
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.observeActivation(app)
                self?.refreshHUD()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, self.gameApplication?.processIdentifier == app.processIdentifier else { return }
                self.endSession()
            }
        })
    }

    func beginSession(game: Game, application: NSRunningApplication?, managedPID: pid_t? = nil) {
        recordPlaytime()
        resetSessionControls()
        hide(restoreFocus: false)
        self.game = game
        self.managedPID = managedPID
        sessionStarted = Date()
        sampler.reset(); sample = nil
        gameApplication = application.flatMap { app in
            game.source == .ps2 || matches(app, game: game) ? app : nil
        }
        if managedPID != nil || gameApplication != nil { playtimeStarted = ProcessInfo.processInfo.systemUptime }
        message = nil
        GameFullScreenEnforcer.shared.beginSession(game: game, application: application)
    }

    func endSession() {
        recordPlaytime()
        resetSessionControls()
        hide(restoreFocus: false)
        gameApplication = nil
        managedPID = nil
        game = nil
        sessionStarted = nil
        sample = nil
        selection = 0
        GameFullScreenEnforcer.shared.endSession()
    }

    private func recordPlaytime() {
        guard let playtimeStarted else { return }
        self.playtimeStarted = nil
        if let game {
            store?.recordPlaytime(gameID: game.id, seconds: ProcessInfo.processInfo.systemUptime - playtimeStarted)
        }
    }

    var canToggle: Bool {
        if isVisible || NSApp.isActive { return true }
        guard let game, let front = NSWorkspace.shared.frontmostApplication else { return false }
        return matches(front, game: game)
    }

    func toggle() {
        if isVisible { hide(restoreFocus: true) }
        else if canToggle { showFromLibrary() }
    }

    /// Also provides a preview when no game is running, without launching anything.
    func showFromLibrary() {
        if let app = gameApplication, app.isTerminated { endSession() }
        previousApplication = NSWorkspace.shared.frontmostApplication
        selection = 0; message = nil; showingConsole = false; showingRemap = false
        if panel == nil {
            let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: GameOverlayView(overlay: self).preferredColorScheme(.dark))
            panel.command = { [weak self] in _ = self?.route($0, fromController: false) }
            self.panel = panel
        }
        guard let screen = targetScreen else { return }
        positionGuide(on: screen)
        isVisible = true
        hudPanel?.orderOut(nil)
        startSampling()
        panel?.alphaValue = ConsoleFeedback.shared.motionReduced ? 1 : 0
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if !ConsoleFeedback.shared.motionReduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel?.animator().alphaValue = 1
            }
        }
        if keyboardMonitor == nil {
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible, event.window === self.panel else { return event }
                let commands: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "confirm", 49: "confirm", 76: "confirm", 53: "back", 1: "capture"]
                guard let command = commands[event.keyCode] else { return event }
                if event.isARepeat, ConsoleDirection(rawValue: command) == nil { return nil }
                ConsoleFeedback.shared.respond(to: command)
                self.route(command, fromController: false)
                return nil
            }
        }
    }

    func hide(restoreFocus: Bool) {
        panel?.orderOut(nil); isVisible = false
        showingConsole = false
        showingRemap = false
        if !hudEnabled { stopSampling() }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        if restoreFocus {
            let target = previousApplication?.isTerminated == false ? previousApplication : gameApplication
            target?.activate(options: [])
        }
        refreshHUD()
    }

    @discardableResult
    func route(_ raw: String, fromController: Bool = true) -> Bool {
        guard isVisible else { return false }
        let command = fromController ? profile.map(raw) : raw
        if showingConsole {
            switch command {
            case "back", "menu": setConsoleVisible(false)
            case "home": hide(restoreFocus: true)
            case "confirm": perform(.resume)
            default: break
            }
            return true
        }
        if let direction = ConsoleDirection(rawValue: command),
           let action = focusedAction, let next = guideGraph[action]?[direction] {
            focus(next)
            return true
        }
        switch command {
        case "home": hide(restoreFocus: true)
        case "back", "menu":
            if showingRemap { showRemap(false) } else { hide(restoreFocus: true) }
        case "previous": focusStep(-1)
        case "next": focusStep(1)
        case "confirm":
            if let action = focusedAction { perform(action) }
        case "favorite" where !showingRemap: perform(.favorite)
        case "details" where !showingRemap, "capture" where !showingRemap: perform(.capture)
        default: break
        }
        return true
    }

    fileprivate var profile: ConsoleGuideProfile {
        guard let id = game?.id else { return .southConfirm }
        return store?.data.games.first(where: { $0.id == id })?.guideProfile ?? .southConfirm
    }

    private var runtime: ConsoleGameRuntime? {
        game.flatMap { ConsoleGameRuntimes.shared.providers[$0.source] }
    }

    fileprivate var canQuickSave: Bool { runtime?.quickSave != nil }
    fileprivate var canQuickLoad: Bool { runtime?.quickLoad != nil }
    fileprivate var actions: [OverlayAction] {
        if showingRemap { return [.bottomConfirms, .rightConfirms, .backToGuide] }
        var actions: [OverlayAction] = [.resume, .performance, .capture]
        if game != nil {
            if canQuickSave { actions.append(.quickSave) }
            if canQuickLoad { actions.append(.quickLoad) }
            actions += [.remap, .favorite]
        }
        if store?.hasRunningNXNativeGame == true { actions.append(.console) }
        actions.append(.home)
        return actions
    }
    fileprivate var actionRows: [[OverlayAction]] {
        stride(from: 0, to: actions.count, by: 3).map { Array(actions[$0..<min($0 + 3, actions.count)]) }
    }
    private var guideGraph: [OverlayAction: [ConsoleDirection: OverlayAction]] { consoleGridNeighbors(actionRows) }
    fileprivate var focusedAction: OverlayAction? { actions.indices.contains(selection) ? actions[selection] : actions.first }

    fileprivate func focus(_ action: OverlayAction) {
        if let index = actions.firstIndex(of: action) { selection = index }
    }

    private func focusStep(_ delta: Int) {
        selection = (min(selection, actions.count - 1) + delta + actions.count) % actions.count
    }

    fileprivate var consoleLog: String { store?.gameConsoleLog ?? "" }
    fileprivate var isFavorite: Bool {
        guard let id = game?.id else { return false }
        return store?.data.games.first { $0.id == id }?.favorite ?? false
    }

    private var canQuitGame: Bool {
        guard let game, OverlayApplicationPolicy.permitsQuit(source: game.source) else { return false }
        if managedPID != nil { return store?.hasRunningNXNativeGame == true }
        guard let app = gameApplication, !app.isTerminated else { return false }
        return matches(app, game: game)
    }

    fileprivate func title(for action: OverlayAction) -> String {
        switch action {
        case .resume: game == nil ? "Close" : "Resume"
        case .quickSave: "Quick Save"
        case .quickLoad: "Quick Load"
        case .performance: hudEnabled ? "Hide Performance HUD" : "Show Performance HUD"
        case .remap: "Controller Remap"
        case .capture: "Capture"
        case .home: canQuitGame ? "Exit to Home" : "Home"
        case .console: "Game Console"
        case .favorite: isFavorite ? "Favorited" : "Favorite"
        case .bottomConfirms: ConsoleGuideProfile.southConfirm.title
        case .rightConfirms: ConsoleGuideProfile.eastConfirm.title
        case .backToGuide: "Back to Guide"
        }
    }

    fileprivate func isSelected(_ action: OverlayAction) -> Bool {
        switch action {
        case .bottomConfirms: profile == .southConfirm
        case .rightConfirms: profile == .eastConfirm
        case .performance: hudEnabled
        case .favorite: isFavorite
        default: false
        }
    }

    fileprivate func perform(_ action: OverlayAction) {
        guard !busy || action == .resume else { return }
        switch action {
        case .resume:
            if let app = gameApplication, !app.isTerminated {
                hide(restoreFocus: false)
                app.activate(options: [])
                refreshHUD()
            } else { hide(restoreFocus: true) }
        case .home:
            if canQuitGame, managedPID != nil {
                store?.closeCurrentGame()
            } else if canQuitGame, let app = gameApplication, !app.terminate() {
                message = "The game did not accept the quit request."
                return
            }
            hide(restoreFocus: false)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        case .capture:
            takeScreenshot()
        case .quickSave, .quickLoad:
            guard let game, let perform = action == .quickSave ? runtime?.quickSave : runtime?.quickLoad else { return }
            runOperation {
                try await perform(game)
                return action == .quickSave ? "State saved." : "State loaded."
            }
        case .performance:
            guard game != nil else { message = "Launch a game to use the Performance HUD."; return }
            hudEnabled.toggle()
            message = hudEnabled ? "Performance HUD will appear when you resume." : "Performance HUD hidden."
            refreshHUD()
        case .remap: showRemap(true)
        case .bottomConfirms, .rightConfirms:
            if let id = game?.id {
                store?.setGuideProfile(action == .bottomConfirms ? .southConfirm : .eastConfirm, gameID: id)
                message = "Guide mapping saved."
            }
        case .backToGuide: showRemap(false)
        case .console: setConsoleVisible(true)
        case .favorite:
            if let game { store?.favorite(game) }
        }
    }

    private func showRemap(_ visible: Bool) {
        showingRemap = visible
        focus(visible ? (profile == .southConfirm ? .bottomConfirms : .rightConfirms) : .remap)
    }

    private func setConsoleVisible(_ visible: Bool) {
        showingConsole = visible
        if isVisible, let screen = panel?.screen ?? targetScreen { positionGuide(on: screen) }
    }

    private var targetScreen: NSScreen? {
        if let pid = gameApplication?.processIdentifier ?? managedPID,
           let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
           let mainDisplay = NSScreen.screens.first,
           let window = windows.first(where: {
               $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
           }),
           let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] {
            let center = CGPoint(x: x + w / 2, y: mainDisplay.frame.maxY - y - h / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        return NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    private func positionGuide(on screen: NSScreen) {
        let area = screen.visibleFrame
        let width = min(showingConsole ? 1180.0 : 1000.0, area.width - 48)
        let height = min(showingConsole ? 680.0 : 520.0, area.height - 48)
        let y = showingConsole ? area.midY - height / 2 : area.minY + 24
        panel?.setFrame(NSRect(x: area.midX - width / 2, y: y, width: width, height: height), display: true)
    }

    private func takeScreenshot() {
        guard GameBarCapture.isPermitted else {
            GameBarCapture.requestAccess()
            message = "Allow Screen Recording for MetalOS in macOS Settings to capture screenshots."
            return
        }
        panel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        runOperation(restorePanel: true) {
            try await Task.sleep(for: .milliseconds(250))
            _ = try await GameBarCapture.capture().get()
            return "Screenshot saved to Pictures/MetalOS."
        }
    }

    private func runOperation(restorePanel: Bool = false, _ action: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        let id = UUID()
        operationID = id
        busy = true
        operation = Task { @MainActor [weak self] in
            let result: String
            do { result = try await action() }
            catch { result = error.localizedDescription }
            guard let self, operationID == id else { return }
            busy = false
            operation = nil
            operationID = nil
            if isVisible {
                message = result
                if restorePanel {
                    panel?.orderFrontRegardless()
                    panel?.makeKey()
                }
            } else {
                refreshHUD()
            }
        }
    }

    private func resetSessionControls() {
        hudEnabled = false
        hudPanel?.orderOut(nil)
        operation?.cancel()
        operation = nil
        operationID = nil
        busy = false
    }

    private func refreshHUD() {
        guard hudEnabled, !isVisible, !busy, let game,
              let front = NSWorkspace.shared.frontmostApplication,
              matches(front, game: game), let screen = targetScreen else {
            hudPanel?.orderOut(nil)
            if !isVisible { stopSampling() }
            return
        }
        let hud = hudPanel ?? makeHUDPanel()
        let area = screen.visibleFrame
        hud.setFrame(NSRect(x: area.maxX - 342, y: area.maxY - 162, width: 316, height: 138), display: true)
        if sampleTimer == nil { startSampling() }
        hud.orderFrontRegardless()
    }

    private func makeHUDPanel() -> NSPanel {
        let hud = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hud.hidesOnDeactivate = false
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.contentView = NSHostingView(rootView: GuidePerformanceView(overlay: self).preferredColorScheme(.dark))
        hudPanel = hud
        return hud
    }

    private func startSampling() {
        sampler.reset(); sample = nil
        updateSample()
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSample() }
        }
    }
    private func stopSampling() {
        sampleTimer?.invalidate(); sampleTimer = nil
        sampler.reset(); sample = nil; frames = nil
    }
    private func updateSample() {
        if let pid = gameApplication?.processIdentifier ?? managedPID { sample = sampler.sample(pid: pid) }
        else { sample = nil }
        frames = game.flatMap { runtime?.frames?($0) }
    }
    private func observeActivation(_ app: NSRunningApplication) {
        guard let game, matches(app, game: game) else { return }
        gameApplication = app
        if playtimeStarted == nil { playtimeStarted = ProcessInfo.processInfo.systemUptime }
    }
    private func matches(_ app: NSRunningApplication, game: Game) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return false }
        if game.source == .ps2 {
            return gameApplication?.processIdentifier == app.processIdentifier
        }
        return OverlayApplicationPolicy.matches(installPath: game.installPath, bundleURL: app.bundleURL, executableURL: app.executableURL, bundleIdentifier: app.bundleIdentifier)
    }
}

private final class OverlayPanel: NSPanel {
    var command: ((String) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { command?("back") }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: command?("left")
        case 124: command?("right")
        case 125: command?("down")
        case 126: command?("up")
        case 36, 49, 76: command?("confirm")
        case 53: command?("back")
        default: super.keyDown(with: event)
        }
    }
}

private struct GameOverlayView: View {
    @ObservedObject var overlay: GameOverlayController
    @ObservedObject private var appearance = StudioAppearance.shared
    @FocusState private var focused: OverlayAction?

    var body: some View {
        ConsoleCard(cornerRadius: ConsoleDesign.Radius.overlay, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if overlay.showingConsole {
                    consoleOutput
                    HStack {
                        Button("Back to Guide") { _ = overlay.route("back", fromController: false) }
                        Button("Resume") { overlay.perform(.resume) }
                    }
                    .font(ConsoleDesign.Typography.action)
                    .buttonStyle(.bordered)
                } else {
                    if overlay.game != nil && !overlay.showingRemap { controlCenterCards }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if overlay.showingRemap {
                                    Text("Choose which face button confirms in the MetalOS Guide.")
                                        .font(ConsoleDesign.Typography.metadata)
                                } else {
                                    guideSummary
                                }
                                ForEach(Array(overlay.actionRows.enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: 12) {
                                        ForEach(row) { action in actionTile(action).id(action) }
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: overlay.focusedAction) { _, action in
                            guard let action else { return }
                            focused = action
                            withAnimation(ConsoleFeedback.shared.pageAnimation) { proxy.scrollTo(action) }
                        }
                    }
                    if overlay.game != nil && !overlay.showingRemap { controlCenterDock }
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .consoleMotion()
        .animation(ConsoleFeedback.shared.pageAnimation, value: overlay.showingRemap)
        .onChange(of: overlay.isVisible) { _, visible in
            focused = visible ? overlay.focusedAction : nil
        }
        .onChange(of: overlay.showingConsole) { _, showing in
            if !showing { focused = overlay.focusedAction }
        }
        .onChange(of: focused) { _, action in if let action { overlay.focus(action) } }
        .onExitCommand { _ = overlay.route("back", fromController: false) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: overlay.showingConsole ? "terminal.fill" : "gamecontroller.fill")
                .font(.system(size: 24)).foregroundStyle(appearance.accent)
                .frame(width: 50, height: 50)
                .background(appearance.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(overlay.showingConsole ? "Game Console" : overlay.showingRemap ? "Controller Remap" : "Guide")
                    .font(ConsoleDesign.Typography.heading)
                    .accessibilityAddTraits(.isHeader)
                if let title = overlay.game?.title {
                    Text(title).font(ConsoleDesign.Typography.metadata)
                        .foregroundStyle(ConsoleDesign.Palette.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let started = overlay.sessionStarted {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    Text(GameBarFormatting.duration(tick.date.timeIntervalSince(started)))
                        .font(ConsoleDesign.Typography.metadata)
                        .accessibilityLabel("Session duration")
                }
            }
            ControllerBatteryBadge()
        }
    }

    private var guideSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if overlay.game != nil {
                HStack(spacing: 18) {
                    Text("CPU  \(GameBarFormatting.cpu(overlay.sample?.cpuPercent))")
                    Text("Memory  \(GameBarFormatting.memory(overlay.sample?.memoryBytes))")
                }
                if !overlay.canQuickSave || !overlay.canQuickLoad {
                    let unavailable = !overlay.canQuickSave && !overlay.canQuickLoad ? "Quick Save and Load"
                        : !overlay.canQuickSave ? "Quick Save" : "Quick Load"
                    Text("\(unavailable) are managed by this game or its runtime.")
                }
            }
        }
        .font(ConsoleDesign.Typography.metadata)
        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
    }

    private var controlCenterCards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                controlCenterCard("Activities", "Continue your current objective", symbol: "figure.run", detail: "3 activities · about 2 hours") {
                    overlay.perform(.resume)
                }
                controlCenterCard("Official News", "The latest from the game", symbol: "newspaper", detail: "Updates and community stories") {
                    overlay.perform(.performance)
                }
                controlCenterCard("Recent Captures", "Screenshots and video clips", symbol: "photo.on.rectangle", detail: "Open capture tools") {
                    overlay.perform(.capture)
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .frame(height: 88)
    }

    private func controlCenterCard(_ title: String, _ headline: String, symbol: String, detail: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(appearance.accent)
                    .frame(width: 34, height: 34).background(appearance.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(headline).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.57)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 255, height: 72, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(ConsoleButtonStyle())
    }

    private var controlCenterDock: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                dockItem("Home", "house.fill")
                dockItem("Switcher", "rectangle.stack")
                dockItem("Notifications", "bell.badge")
                dockItem("Game Base", "person.2.fill")
                dockItem("Music", "music.note")
                dockItem("Sound", "speaker.wave.2.fill")
                dockItem("Mic", "mic.fill")
                dockItem("Accessories", "gamecontroller.fill")
                dockItem("Profile", "person.crop.circle")
                dockItem("Power", "power")
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(ConsoleDesign.Palette.border).frame(height: 1) }
    }

    private func dockItem(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
            Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.72))
        .frame(minWidth: 63, minHeight: 47)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func actionTile(_ action: OverlayAction) -> some View {
        FocusableButton(id: action, focus: $focused, accent: appearance.accent, horizontalPadding: 14,
                        prominent: action == .resume, action: { overlay.perform(action) }) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).accessibilityHidden(true)
                Text(overlay.title(for: action))
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if overlay.isSelected(action) {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
        .accessibilityAddTraits(overlay.isSelected(action) ? [.isSelected] : [])
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = overlay.message {
                Text(message).font(ConsoleDesign.Typography.metadata).lineLimit(2)
            }
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    ConsolePromptGlyph(control: overlay.profile.confirmGlyph, fallbackLabel: "↵")
                    Text(overlay.showingConsole ? "Resume" : "Select")
                }
                HStack(spacing: 6) {
                    ConsolePromptGlyph(control: overlay.profile.backGlyph, fallbackLabel: "Esc")
                    Text(overlay.showingRemap || overlay.showingConsole ? "Back" : "Resume")
                }
                if !overlay.showingRemap && !overlay.showingConsole {
                    HStack(spacing: 6) {
                        ConsolePromptGlyph(control: .details, fallbackLabel: "S")
                        Text("Capture")
                    }
                }
                Spacer()
                if overlay.busy { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(ConsoleDesign.Palette.border).frame(height: 1) }
    }

    private var consoleLines: [String] {
        Array(overlay.consoleLog.components(separatedBy: .newlines).suffix(1200))
    }

    private var consoleOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if consoleLines.isEmpty || (consoleLines.count == 1 && consoleLines[0].isEmpty) {
                        Text("Waiting for game output…").foregroundStyle(.secondary).padding(12)
                    } else {
                        ForEach(Array(consoleLines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }.padding(12)
            }
            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
            .onAppear { scrollConsoleToEnd(proxy) }
            .onChange(of: overlay.consoleLog) { _, _ in scrollConsoleToEnd(proxy) }
        }
    }

    private func logColor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("fatal") || lower.contains("error") || lower.contains("assertion failed") || lower.contains("panic") { return .red.opacity(0.9) }
        if lower.contains("warning") || lower.contains("warn:") { return .orange.opacity(0.9) }
        return .white.opacity(0.78)
    }

    private func scrollConsoleToEnd(_ proxy: ScrollViewProxy) {
        let count = consoleLines.count
        guard count > 0 else { return }
        DispatchQueue.main.async { proxy.scrollTo(count - 1, anchor: .bottom) }
    }
}

private struct GuidePerformanceView: View {
    @ObservedObject var overlay: GameOverlayController
    @ObservedObject private var preferences = ConsolePreferences.shared

    var body: some View {
        ConsoleCard(cornerRadius: 18, padding: 13) {
            VStack(alignment: .leading, spacing: 9) {
                Label("Performance", systemImage: "speedometer")
                    .font(.system(size: 17, weight: .semibold))
                Text("CPU \(GameBarFormatting.cpu(overlay.sample?.cpuPercent))  ·  RAM \(GameBarFormatting.memory(overlay.sample?.memoryBytes))")
                if preferences.verboseHUD, let frames = overlay.frames {
                    Text(metric(frames.framesPerSecond, suffix: " fps")
                         + "  ·  " + metric(frames.frameIntervalMilliseconds, suffix: " ms/frame"))
                    Text("Metal GPU  " + metric(frames.gpuMilliseconds, suffix: " ms"))
                } else if preferences.verboseHUD {
                    Text("Frame and Metal metrics unavailable")
                        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
                }
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func metric(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + suffix
    }
}
