import AppKit
import ApplicationServices

/// Puts a launched game into macOS full screen as soon as its window appears.
///
/// macOS has no launch-time full-screen switch for another app, so this uses the
/// Accessibility API to set the standard window's `AXFullScreen` attribute. The first
/// launch asks for Accessibility access; without it the game keeps the presentation
/// mode it chose. A player who leaves full screen later in the session is not forced back.
@MainActor
final class GameFullScreenEnforcer {
    static let shared = GameFullScreenEnforcer()

    private weak var store: LibraryStore?
    private var game: Game?
    private var enforcedProcesses: Set<pid_t> = []
    private var attempt: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var askedForAccess = false

    private var isEnabled: Bool { store?.data.settings.startGamesFullScreen != false }

    func configure(store: LibraryStore) {
        self.store = store
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in self?.consider(application) }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, self.enforcedProcesses.contains(application.processIdentifier) else { return }
                self.endSession()
            }
        })
    }

    func beginSession(game: Game, application: NSRunningApplication?) {
        attempt?.cancel(); attempt = nil
        enforcedProcesses.removeAll()
        self.game = game
        guard isEnabled else { return }
        if let application { consider(application) }
        // The game may have activated before the launcher learned it belongs to this title.
        for running in NSWorkspace.shared.runningApplications { consider(running) }
    }

    func endSession() {
        attempt?.cancel(); attempt = nil
        game = nil
        enforcedProcesses.removeAll()
    }

    /// Called for every app activation and launch while a game session is open.
    private func consider(_ application: NSRunningApplication) {
        guard isEnabled, let game, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !enforcedProcesses.contains(application.processIdentifier),
              OverlayApplicationPolicy.matches(installPath: game.installPath, bundleURL: application.bundleURL,
                                               executableURL: application.executableURL, bundleIdentifier: application.bundleIdentifier)
        else { return }
        requestAccessIfNeeded()
        guard AXIsProcessTrusted() else { return }
        attempt?.cancel()
        let pid = application.processIdentifier
        let gameID = game.id
        attempt = Task { @MainActor [weak self] in
            // Games create their window soon after activation, but loading may take a moment.
            for _ in 0..<60 {
                guard let self, !Task.isCancelled, self.game?.id == gameID, self.isEnabled, !application.isTerminated else { return }
                switch self.applyFullScreen(pid: pid) {
                case .applied:
                    self.enforcedProcesses.insert(pid)
                    return
                case .unsupported:
                    return
                case .retry:
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    private func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted(), !askedForAccess else { return }
        askedForAccess = true
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        store?.notice = "Allow MetalOS under System Settings → Privacy & Security → Accessibility to start games in full screen."
    }

    private enum FullScreenAttempt { case applied, retry, unsupported }

    private func applyFullScreen(pid: pid_t) -> FullScreenAttempt {
        let application = AXUIElementCreateApplication(pid)
        guard let window = targetWindow(of: application) else { return .retry }
        var current: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &current)
        if status == .attributeUnsupported || status == .apiDisabled { return .unsupported }
        if status == .success, let isFullScreen = current as? Bool, isFullScreen { return .applied }
        switch AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) {
        case .success: return .applied
        case .attributeUnsupported, .apiDisabled: return .unsupported
        default: return .retry
        }
    }

    private func targetWindow(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value) == .success,
           let mainWindow = value {
            return (mainWindow as! AXUIElement)
        }
        value = nil
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            return windows.first
        }
        return nil
    }
}
