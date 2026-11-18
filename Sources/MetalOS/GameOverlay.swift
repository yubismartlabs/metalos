import SwiftUI
import AppKit
import Combine

/// Determines ownership from an installed payload, never from the last activated app alone.
struct OverlayApplicationPolicy {
    static func permitsQuit(source: GameSource) -> Bool {
        [.native, .appStore, .nxnative].contains(source)
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
    case resume, library, screenshot, console, favorite, quit
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .resume: "play.fill"
        case .library: "square.grid.2x2.fill"
        case .screenshot: "camera.fill"
        case .console: "terminal.fill"
        case .favorite: "heart.fill"
        case .quit: "power"
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
    private weak var store: LibraryStore?
    private var gameApplication: NSRunningApplication?
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
            Task { @MainActor in self?.observeActivation(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, self.gameApplication?.processIdentifier == app.processIdentifier else { return }
                self.gameApplication = nil; self.game = nil; self.selection = 0; self.sessionStarted = nil
                self.hide(restoreFocus: false)
                GameFullScreenEnforcer.shared.endSession()
            }
        })
    }

    func beginSession(game: Game, application: NSRunningApplication?) {
        hide(restoreFocus: false)
        self.game = game
        sessionStarted = Date()
        sampler.reset(); sample = nil
        gameApplication = application.flatMap { matches($0, game: game) ? $0 : nil }
        message = nil
        GameFullScreenEnforcer.shared.beginSession(game: game, application: application)
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
        if let app = gameApplication, app.isTerminated { gameApplication = nil; game = nil }
        previousApplication = NSWorkspace.shared.frontmostApplication
        selection = 0; message = nil; showingConsole = false
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
            panel.command = { [weak self] in _ = self?.route($0) }
            self.panel = panel
        }
        // Prefer the game's display; otherwise the display under the pointer.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let width = min(showingConsole ? 1180.0 : 1000.0, screen.visibleFrame.width - 64)
        let height = showingConsole ? min(680.0, screen.visibleFrame.height - 64) : 300.0
        let y = showingConsole ? screen.visibleFrame.midY - height / 2 : screen.visibleFrame.minY + 36
        panel?.setFrame(NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height), display: true)
        isVisible = true
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
                let commands: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "confirm", 49: "confirm", 53: "back", 1: "capture"]
                guard let command = commands[event.keyCode] else { return event }
                ConsoleFeedback.shared.respond(to: command)
                self.route(command)
                return nil
            }
        }
    }

    func hide(restoreFocus: Bool) {
        panel?.orderOut(nil); isVisible = false
        showingConsole = false
        stopSampling()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        if restoreFocus {
            let target = previousApplication?.isTerminated == false ? previousApplication : gameApplication
            target?.activate(options: [])
        }
    }

    @discardableResult
    func route(_ command: String) -> Bool {
        guard isVisible else { return false }
        if showingConsole {
            switch command {
            case "back", "menu": setConsoleVisible(false)
            case "confirm": perform(.resume)
            default: break
            }
            return true
        }
        switch command {
        case "back", "menu": hide(restoreFocus: true)
        case "left", "previous", "up": selection = (selection - 1 + actions.count) % actions.count
        case "right", "next", "down": selection = (selection + 1) % actions.count
        case "confirm": perform(actions[min(selection, actions.count - 1)])
        case "favorite": perform(.favorite)
        case "details", "capture": perform(.screenshot)
        default: break
        }
        return true
    }

    fileprivate var actions: [OverlayAction] {
        var actions: [OverlayAction] = [.resume, .library, .screenshot]
        if canShowConsole { actions.append(.console) }
        if game != nil { actions.append(.favorite) }
        if canQuitGame { actions.append(.quit) }
        return actions
    }
    fileprivate var canShowConsole: Bool { store?.hasRunningNXNativeGame == true }
    fileprivate var consoleLog: String { store?.gameConsoleLog ?? "" }
    fileprivate var isFavorite: Bool {
        guard let id = game?.id else { return false }
        return store?.data.games.first { $0.id == id }?.favorite ?? false
    }
    private var canQuitGame: Bool {
        guard let game, OverlayApplicationPolicy.permitsQuit(source: game.source), let app = gameApplication, !app.isTerminated else { return false }
        return matches(app, game: game)
    }
    fileprivate func title(for action: OverlayAction) -> String {
        switch action {
        case .resume: game == nil ? "Close" : "Resume"
        case .library: "Library"
        case .screenshot: "Capture"
        case .console: "Console"
        case .favorite: isFavorite ? "Favorited" : "Favorite"
        case .quit: "Quit game"
        }
    }
    fileprivate func detail(for action: OverlayAction) -> String {
        switch action {
        case .resume: game == nil ? "Close the bar" : "Back to the game"
        case .library: "Open MetalOS"
        case .screenshot: "Save a screenshot"
        case .console: "View live game output"
        case .favorite: isFavorite ? "Remove favorite" : "Add to favorites"
        case .quit: "End this game"
        }
    }
    fileprivate func perform(_ action: OverlayAction) {
        switch action {
        case .resume:
            if let app = gameApplication, !app.isTerminated {
                hide(restoreFocus: false)
                app.activate(options: [])
            } else { hide(restoreFocus: true) }
        case .library:
            hide(restoreFocus: false)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        case .screenshot:
            takeScreenshot()
        case .console:
            setConsoleVisible(true)
        case .favorite:
            if let game { store?.favorite(game) }
        case .quit:
            guard canQuitGame, let app = gameApplication else { return }
            if app.terminate() { hide(restoreFocus: false) }
            else { message = "The game did not accept the quit request. Close it from its own menu." }
        }
    }
    private func setConsoleVisible(_ visible: Bool) {
        showingConsole = visible
        guard isVisible, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
              let panel else { return }
        let width = min(visible ? 1180.0 : 1000.0, screen.visibleFrame.width - 64)
        let height = visible ? min(680.0, screen.visibleFrame.height - 64) : 300.0
        let y = visible ? screen.visibleFrame.midY - height / 2 : screen.visibleFrame.minY + 36
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height), display: true)
    }
    private func takeScreenshot() {
        guard GameBarCapture.isPermitted else {
            GameBarCapture.requestAccess()
            message = "Allow MetalOS under System Settings → Privacy & Security → Screen Recording, then relaunch to save screenshots."
            return
        }
        panel?.orderOut(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let result = await GameBarCapture.capture()
            guard let self else { return }
            switch result {
            case .success: self.message = "Screenshot saved to Pictures/MetalOS."
            case .failure: self.message = "Could not save the screenshot."
            }
            if self.isVisible {
                self.panel?.orderFrontRegardless()
                self.panel?.makeKey()
            }
        }
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
        sampler.reset(); sample = nil
    }
    private func updateSample() {
        guard let pid = gameApplication?.processIdentifier else { sample = nil; return }
        sample = sampler.sample(pid: pid)
    }
    private func observeActivation(_ app: NSRunningApplication) {
        guard let game, matches(app, game: game) else { return }
        gameApplication = app
    }
    private func matches(_ app: NSRunningApplication, game: Game) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return false }
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
    var body: some View {
        VStack(spacing: 14) {
            if overlay.showingConsole {
                consoleHeader
                consoleOutput
                HStack {
                    Text("B / Esc  Back to Game Bar     A / Enter  Resume Game")
                    Spacer()
                    Text("LIVE NXNATIVE OUTPUT").foregroundStyle(studioAccent)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                header
                HStack(alignment: .top, spacing: 12) {
                    performance
                    ForEach(Array(overlay.actions.enumerated()), id: \.element.id) { index, action in
                        actionTile(action, selected: overlay.selection == index)
                    }
                }
                footer
            }
        }.padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27))
            .background(studioBackground.opacity(0.93), in: RoundedRectangle(cornerRadius: 27))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(.white.opacity(0.12)))
            .padding(12)
            .consoleMotion()
            .environment(\.consoleOverlayFocus, true)
            .animation(ConsoleFeedback.shared.focusAnimation, value: overlay.selection)
            .onExitCommand { overlay.hide(restoreFocus: true) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 21)).foregroundStyle(studioAccent)
                .frame(width: 44, height: 44)
                .background(studioAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("GAME BAR").font(.system(size: 9, weight: .bold)).tracking(3).foregroundStyle(studioAccent)
                Text(overlay.game?.title ?? "No game running").font(.system(size: 20, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if overlay.game != nil, let started = overlay.sessionStarted {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("SESSION").font(.system(size: 8, weight: .bold)).tracking(2).foregroundStyle(.secondary)
                        Text(GameBarFormatting.duration(context.date.timeIntervalSince(started)))
                            .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            VStack(alignment: .trailing, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, style: .time).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                ControllerBatteryBadge()
            }
        }
    }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer").font(.system(size: 10))
                Text("PERFORMANCE").font(.system(size: 9, weight: .bold)).tracking(2)
            }.foregroundStyle(studioAccent)
            HStack(spacing: 20) {
                metric("CPU", GameBarFormatting.cpu(overlay.sample?.cpuPercent))
                metric("MEMORY", GameBarFormatting.memory(overlay.sample?.memoryBytes))
            }
            Spacer(minLength: 0)
            Text(overlay.game == nil ? "Launch a game to read its process." : overlay.sample == nil ? "Waiting for the game process…" : "Reads the game process only.")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14)
            .frame(width: 210, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.07)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
    }

    private func actionTile(_ action: OverlayAction, selected: Bool) -> some View {
        Button { overlay.perform(action) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: action.symbol).font(.system(size: 20, weight: .medium))
                    Spacer()
                    if action == .favorite && overlay.isFavorite {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    }
                }
                Spacer(minLength: 0)
                Text(overlay.title(for: action)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(overlay.detail(for: action)).font(.system(size: 9)).lineLimit(1).opacity(0.6)
            }.padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 116)
                .foregroundStyle(selected ? studioBackground : .white.opacity(0.85))
                .background(selected ? studioAccent : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? Color.clear : .white.opacity(0.07)))
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selected, cornerRadius: 15, scale: 1.025)
    }

    private var footer: some View {
        HStack {
            Text(overlay.message ?? "← → Select    A / Return Confirm    X / S Capture    B / Esc Resume")
            Spacer()
            Text("LB + RB + Menu").foregroundStyle(studioAccent)
        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }

    private var consoleHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill").font(.system(size: 18)).foregroundStyle(studioAccent)
                .frame(width: 38, height: 38).background(studioAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text("GAME CONSOLE").font(.system(size: 9, weight: .bold)).tracking(3).foregroundStyle(studioAccent)
                Text(overlay.game?.title ?? "NXNative output").font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Text("host.log").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
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
