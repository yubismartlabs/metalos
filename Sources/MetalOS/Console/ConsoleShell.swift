import AppKit
import Combine
import Darwin
import GameController
import ServiceManagement
import SwiftUI

@MainActor
final class ConsoleWindowController: NSWindowController {
    private var targetDisplayName: String
    private var screenObserver: NSObjectProtocol?

    init(window: NSWindow, targetDisplayName: String) {
        self.targetDisplayName = targetDisplayName
        super.init(window: window)
        if let screen = Self.resolveScreen(named: targetDisplayName) { configure(window, screen: screen) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.snapToTargetDisplay() }
            }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        guard let window, let screen = Self.resolveScreen(named: targetDisplayName) else { return }
        configure(window, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func hideForExternalApp() {
        window?.orderOut(nil)
    }

    func setTargetDisplay(named name: String) {
        targetDisplayName = name
        snapToTargetDisplay()
    }

    func snapToTargetDisplay() {
        guard let window, let screen = Self.resolveScreen(named: targetDisplayName) else { return }
        configure(window, screen: screen)
        window.setFrame(screen.frame, display: true)
    }

    private func configure(_ window: NSWindow, screen: NSScreen) {
        window.styleMask = [.borderless, .fullSizeContentView]
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.level = .normal
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: true)
    }

    private static func resolveScreen(named name: String) -> NSScreen? {
        guard let requested = NSScreen.screens.first(where: { $0.localizedName == name }) else {
            return NSScreen.main ?? NSScreen.screens.first
        }
        guard let requestedID = displayID(for: requested) else { return requested }
        return NSScreen.screens.first(where: { displayID(for: $0) == requestedID }) ?? requested
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class ConsoleCursorManager {
    static let shared = ConsoleCursorManager()
    private(set) var isCursorHidden = false
    private init() {}

    func hide() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    func unhide() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }
}

enum ConsoleLoginItemStatus: Equatable {
    case enabled, requiresApproval, notRegistered
    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required in System Settings"
        case .notRegistered: "Not enabled"
        }
    }
}

@MainActor
final class ConsoleModeManager: ObservableObject {
    static let shared = ConsoleModeManager()
    @Published private(set) var status: ConsoleLoginItemStatus = .notRegistered
    @Published private(set) var errorMessage: String?

    private init() { refresh() }
    var isEnabled: Bool { status == .enabled }

    func refresh() {
        status = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .notRegistered
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
            if status == .requiresApproval {
                ConsoleToastManager.shared.post("Login Item Needs Approval", "Open System Settings → Login Items to approve Console Mode.", symbol: "person.crop.circle.badge.exclamationmark", priority: .warning, deduplicationKey: "login-item-approval")
            }
        } catch {
            errorMessage = error.localizedDescription
            refresh()
            ConsoleToastManager.shared.post("Console Mode Could Not Be Changed", error.localizedDescription, symbol: "exclamationmark.triangle.fill", priority: .warning)
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class ConsoleShellCoordinator: ObservableObject {
    static let shared = ConsoleShellCoordinator()
    @Published private(set) var isYieldedToExternalApp = false
    @Published private(set) var isTransitioningToExternalApp = false
    @Published private(set) var activeExternalAppTitle: String?

    private var windowController: ConsoleWindowController?
    private weak var inputManager: ConsoleInputManager?
    private weak var focusCoordinator: FocusCoordinator?
    private weak var playtimeTracker: PlaytimeTracker?
    private var activeApplication: NSRunningApplication?
    private var activePID: pid_t?
    private var activeBundleID: String?
    private var activeGameID: String?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var processMonitor: Timer?
    private var mainAppObserver: NSObjectProtocol?

    private init() {}

    func launchShell() {
        guard !didLaunchShell else { return }
        didLaunchShell = true
        observeSystemLifecycle()
        GCController.shouldMonitorBackgroundEvents = true
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
    }

    private var didLaunchShell = false

    func adoptSceneWindow(_ window: NSWindow) {
        guard windowController?.window !== window else { return }
        windowController = ConsoleWindowController(window: window, targetDisplayName: ConsoleSettingsStore.shared.targetDisplay)
        windowController?.show()
        ConsoleCursorManager.shared.hide()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    func register(input: ConsoleInputManager, focus: FocusCoordinator, playtime: PlaytimeTracker) {
        inputManager = input
        focusCoordinator = focus
        playtimeTracker = playtime
        focus.synchronizeExternalAppTitle(activeExternalAppTitle)
    }

    /// ControllerManager is also used by legacy screens and may own the GameController
    /// button handlers after a hot-plug. Forward its unclaimed actions into the console's
    /// semantic input path while the launcher owns the foreground.
    func routeControllerCommand(_ command: String) -> Bool {
        guard !isYieldedToExternalApp, let inputManager else { return false }
        let action: ConsoleInputAction?
        switch command {
        case "up": action = .move(.up)
        case "down": action = .move(.down)
        case "left": action = .move(.left)
        case "right": action = .move(.right)
        case "confirm": action = .confirm
        case "back": action = .back
        case "menu", "context", "details": action = .options
        case "previous": action = .tabLeft
        case "next": action = .tabRight
        case "home": action = .home
        default: action = nil
        }
        guard let action else { return false }
        inputManager.dispatchControllerAction(action)
        return true
    }

    func setTargetDisplay(_ name: String) {
        windowController?.setTargetDisplay(named: name)
    }

    func toggleFullscreen() {
        windowController?.snapToTargetDisplay()
        enforcePresentationOptions()
        showShell()
    }

    func yieldToExternalApp(pid: pid_t?, bundleID: String?, gameID: String?, title: String,
                            application: NSRunningApplication? = nil) {
        if let gameID { playtimeTracker?.recordSessionStart(gameId: gameID) }
        activePID = pid ?? application?.processIdentifier
        activeBundleID = bundleID ?? application?.bundleIdentifier
        activeApplication = application ?? activePID.flatMap(NSRunningApplication.init(processIdentifier:))
        activeGameID = gameID
        activeExternalAppTitle = title
        focusCoordinator?.synchronizeExternalAppTitle(title)
        inputManager?.setForegroundRoutingEnabled(false)
        ConsoleCursorManager.shared.unhide()
        UISoundManager.suspendForGameLaunch()
        NSApp.presentationOptions = []
        windowController?.window?.level = .normal
        withAnimation(ConsoleMotion.zoneSpring) { isTransitioningToExternalApp = true; isYieldedToExternalApp = true }
        watchActiveProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            self?.windowController?.hideForExternalApp()
        }
    }

    func controllerHomePressed() {
        if isYieldedToExternalApp {
            bringShellForwardForResume()
        } else if NSApp.isActive {
            inputManager?.dispatchControllerHome()
        }
    }

    func resumeExternalApp() {
        guard isExternalProcessAlive else { return }
        focusCoordinator?.closeControlCenter()
        inputManager?.setForegroundRoutingEnabled(false)
        ConsoleCursorManager.shared.unhide()
        NSApp.presentationOptions = []
        isTransitioningToExternalApp = true
        isYieldedToExternalApp = true
        windowController?.hideForExternalApp()
        if let activeApplication, !activeApplication.isTerminated {
            activeApplication.activate(options: [.activateAllWindows])
        } else if let pid = activePID {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    func closeActiveExternalApp() {
        guard isExternalProcessAlive else { return }
        if let activeApplication, !activeApplication.isTerminated {
            activeApplication.terminate()
        } else if let pid = activePID {
            _ = kill(pid, SIGTERM)
        }
    }

    func showShell() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        windowController?.snapToTargetDisplay()
        windowController?.show()
        ConsoleCursorManager.shared.hide()
        NSApp.activate(ignoringOtherApps: true)
        inputManager?.setForegroundRoutingEnabled(true)
        withAnimation(ConsoleMotion.zoneSpring) { isTransitioningToExternalApp = false; isYieldedToExternalApp = false }
    }

    func returnFromExternalApp() {
        if let gameID = activeGameID { playtimeTracker?.recordSessionEnd(gameId: gameID) }
        activeApplication = nil
        activePID = nil
        activeBundleID = nil
        activeGameID = nil
        activeExternalAppTitle = nil
        focusCoordinator?.synchronizeExternalAppTitle(nil)
        processMonitor?.invalidate()
        processMonitor = nil
        showShell()
        inputManager?.refreshConnectedControllers()
        UISoundManager.resumeFromGame()
    }

    func exitToDesktop() {
        processMonitor?.invalidate()
        processMonitor = nil
        ConsoleCursorManager.shared.unhide()
        inputManager?.setForegroundRoutingEnabled(false)
        UISoundManager.stopForExit()
        NSApp.presentationOptions = []
        windowController?.close()
        windowController = nil
        NSApp.terminate(nil)
    }

    func recoverAfterWake() {
        guard !isYieldedToExternalApp else { return }
        windowController?.snapToTargetDisplay()
        enforcePresentationOptions()
        inputManager?.refreshConnectedControllers()
        UISoundManager.recoverAfterSystemWake()
        ConsoleToastManager.shared.refreshControllersAfterWake()
        showShell()
    }

    private var isExternalProcessAlive: Bool {
        guard let pid = activePID else { return activeApplication.map { !$0.isTerminated } ?? false }
        if let activeApplication { return !activeApplication.isTerminated }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func bringShellForwardForResume() {
        isYieldedToExternalApp = false
        isTransitioningToExternalApp = false
        inputManager?.setForegroundRoutingEnabled(true)
        ConsoleCursorManager.shared.hide()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        windowController?.snapToTargetDisplay()
        windowController?.show()
        NSApp.activate(ignoringOtherApps: true)
        focusCoordinator?.synchronizeExternalAppTitle(activeExternalAppTitle)
        focusCoordinator?.openControlCenter()
    }

    private func watchActiveProcess() {
        processMonitor?.invalidate()
        processMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isExternalProcessAlive { self.returnFromExternalApp() }
            }
        }
    }

    private func enforcePresentationOptions() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func observeSystemLifecycle() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        terminationObserver = workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in
                    guard self?.activePID == app.processIdentifier else { return }
                    self?.returnFromExternalApp()
                }
            }
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverAfterWake() }
            }
        }
        mainAppObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isYieldedToExternalApp else { return }
                    self.enforcePresentationOptions()
                    self.windowController?.snapToTargetDisplay()
                }
            }
    }
}
