import GameController
import AppKit
import Combine
import CoreHaptics

@MainActor
final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()
    @Published var name: String?
    @Published private(set) var devices: [ControllerStatus] = []
    @Published private(set) var statusUpdatedAt = Date()
    @Published private(set) var activeInputScopeID: UUID?
    /// Real-time input state for the gamepad tester.
    @Published private(set) var buttonStates: [String: Bool] = [:]
    @Published private(set) var leftThumbstick: (x: Float, y: Float) = (0, 0)
    @Published private(set) var rightThumbstick: (x: Float, y: Float) = (0, 0)
    @Published private(set) var leftTrigger: Float = 0
    @Published private(set) var rightTrigger: Float = 0
    @Published private(set) var dpad: (x: Float, y: Float) = (0, 0)
    @Published private(set) var inputSnapshots: [String: GamepadSnapshot] = [:]
    private var testSessions: Set<UUID> = []
    private var hapticEngines: [String: CHHapticEngine] = [:]
    private var hapticPlayers: [String: CHHapticPatternPlayer] = [:]
    private var statusTimer: Timer?
    private var inputHandlers: [(id: UUID, action: (String) -> Void)] = []
    var action: ((String) -> Void)?
    var homeAction: (() -> Void)?
    var priorityAction: ((String) -> Bool)?
    var inactiveAppAction: ((String) -> Bool)?
    /// Lets an active browser consume left-stick motion as a pointer instead of navigation.
    var leftStickPointerAction: ((Float, Float) -> Bool)?
    var overlayAction: (() -> Void)?
    var canToggleOverlay: (() -> Bool)?
    var overlayRoute: ((String) -> Bool)?
    private var observers: [NSObjectProtocol] = []
    private var lastDirection = Date.distantPast
    private var lastToggle = Date.distantPast
    private var repeatTimer: Timer?
    private var heldDirection: String?
    /// References to connected controllers so we can control light, haptics, player index.
    private var connectedControllers: [GCController] = []

    init() {
        // Ordinary game input is gated below; only the overlay chord is observed globally.
        GCController.shouldMonitorBackgroundEvents = true
        for event in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.connect() }
            })
        }
        connect()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }
    func refreshStatus() {
        connectedControllers = GCController.controllers()
        let connectedIDs = Set(connectedControllers.map(Self.deviceID))
        inputSnapshots = inputSnapshots.filter { connectedIDs.contains($0.key) }
        for id in Array(hapticEngines.keys) where !connectedIDs.contains(id) {
            hapticEngines.removeValue(forKey: id)?.stop(completionHandler: nil)
            hapticPlayers.removeValue(forKey: id)
        }
        devices = connectedControllers.map { controller in
            let battery = controller.battery
            let state = ControllerBatteryState(battery?.batteryState)
            let pad = controller.extendedGamepad
            let player = controller.playerIndex.rawValue
            return ControllerStatus(
                id: Self.deviceID(controller),
                name: controller.vendorName ?? "Game controller",
                productCategory: controller.productCategory,
                isAttached: controller.isAttachedToDevice,
                batteryPercent: ControllerBatteryReading.percentage(level: battery?.batteryLevel, state: state),
                batteryState: state,
                playerNumber: player >= 0 && player < 4 ? player + 1 : nil,
                supportsMotion: controller.motion != nil,
                supportsHaptics: !(controller.haptics?.supportedLocalities.isEmpty ?? true),
                supportsLight: controller.light != nil,
                hasOptionsButton: pad?.buttonOptions != nil,
                hasHomeButton: pad?.buttonHome != nil,
                lightPreset: controller.light.flatMap { Self.lightPresetIndex($0.color) }
            )
        }
        statusUpdatedAt = Date()
    }
    @discardableResult
    func pushInputHandler(_ action: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        inputHandlers.append((id, action))
        activeInputScopeID = id
        heldDirection = nil; repeatTimer?.invalidate()
        return id
    }
    func popInputHandler(_ id: UUID) {
        inputHandlers.removeAll { $0.id == id }
        activeInputScopeID = inputHandlers.last?.id
        heldDirection = nil; repeatTimer?.invalidate()
    }
    func connect() {
        refreshStatus()
        name = connectedControllers.first(where: { $0.extendedGamepad != nil })?.vendorName
        if connectedControllers.contains(where: { $0.extendedGamepad != nil }), name == nil { name = "Game controller" }
        heldDirection = nil; repeatTimer?.invalidate()
        buttonStates = [:]; leftThumbstick = (0, 0); rightThumbstick = (0, 0)
        leftTrigger = 0; rightTrigger = 0; dpad = (0, 0)
        for controller in connectedControllers {
            guard let pad = controller.extendedGamepad else { continue }
            controller.handlerQueue = .main
            let deviceID = Self.deviceID(controller)
            inputSnapshots[deviceID] = GamepadSnapshot(pad)
            // The whole-profile callback includes stick clicks and every analog change.
            // Capture before hopping queues so short press/release pairs cannot disappear.
            controller.physicalInputProfile.valueDidChangeHandler = { [weak self, weak pad] _, _ in
                guard let pad else { return }
                let snapshot = GamepadSnapshot(pad)
                Task { @MainActor in self?.inputSnapshots[deviceID] = snapshot }
            }
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.dpad = (x, y)
                    self?.direction(x, y)
                }
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.leftThumbstick = (x, y)
                    if self?.leftStickPointerAction?(x, y) == true { self?.cancelDirectionalRepeat() }
                    else { self?.direction(x, y) }
                }
            }
            pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.rightThumbstick = (x, y)
                }
            }
            let buttons: [(GCControllerButtonInput, String)] = [(pad.buttonA, "confirm"), (pad.buttonB, "back"), (pad.buttonY, "favorite"), (pad.buttonX, "details"), (pad.leftShoulder, "previous"), (pad.rightShoulder, "next"), (pad.buttonMenu, "menu")]
            for (button, command) in buttons {
                button.pressedChangedHandler = { [weak self, weak pad] _, value, pressed in
                    Task { @MainActor in
                        self?.buttonStates[command] = pressed
                        guard pressed, let self, let pad else { return }
                        if self.isOverlayChord(pad) { self.toggleOverlay(); return }
                        self.deliver(command)
                    }
                }
            }
            pad.buttonOptions?.pressedChangedHandler = { [weak self, weak pad] _, value, pressed in
                Task { @MainActor in
                    self?.buttonStates["context"] = pressed
                    guard pressed, let self, let pad else { return }
                    if self.isOverlayChord(pad) { self.toggleOverlay() }
                    else { self.deliver("context") }
                }
            }
            pad.buttonHome?.pressedChangedHandler = { [weak self] _, value, pressed in
                Task { @MainActor in
                    self?.buttonStates["home"] = pressed
                    guard pressed else { return }
                    if !NSApp.isActive, self?.inactiveAppAction?("home") == true { return }
                    if NSApp.isActive, let self {
                        if !self.inputHandlers.isEmpty { self.deliver("home"); return }
                        if let homeAction = self.homeAction { homeAction(); return }
                    }
                    self?.toggleOverlay()
                }
            }
            pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
                Task { @MainActor in
                    self?.leftTrigger = value
                }
            }
            pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
                Task { @MainActor in
                    self?.rightTrigger = value
                }
            }
        }
    }
    private func isOverlayChord(_ pad: GCExtendedGamepad) -> Bool {
        pad.buttonMenu.isPressed && ((pad.leftShoulder.isPressed && pad.rightShoulder.isPressed) || pad.buttonOptions?.isPressed == true)
    }
    private func toggleOverlay() {
        guard testSessions.isEmpty else { return }
        guard Date().timeIntervalSince(lastToggle) > 0.4, canToggleOverlay?() == true else { return }
        lastToggle = Date(); heldDirection = nil; repeatTimer?.invalidate(); ConsoleFeedback.shared.play(.open); overlayAction?()
    }
    private func deliver(_ command: String) {
        // Testing captures raw inputs without operating menus or the in-game overlay.
        guard testSessions.isEmpty else { return }
        if overlayRoute?(command) == true { ConsoleFeedback.shared.respond(to: command); return }
        if !NSApp.isActive {
            if inactiveAppAction?(command) == true { ConsoleFeedback.shared.respond(to: command) }
            return
        }
        guard NSApp.modalWindow == nil else { return }
        ConsoleFeedback.shared.respond(to: command)
        // A modal scope owns input until dismissed. Route to it before global
        // shortcuts so the same press cannot affect the library behind a sheet.
        if let handler = inputHandlers.last { handler.action(command); return }
        if priorityAction?(command) == true { return }
        action?(command)
    }
    private func direction(_ x: Float, _ y: Float) {
        let command: String? = abs(x) > 0.55 ? (x > 0 ? "right" : "left") : abs(y) > 0.55 ? (y > 0 ? "up" : "down") : nil
        guard command != heldDirection else { return }
        heldDirection = command; repeatTimer?.invalidate()
        guard let command else { return }
        deliver(command); lastDirection = Date()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastDirection) > 0.32, let command = self.heldDirection else { return }
                self.deliver(command)
            }
        }
    }
    func cancelDirectionalRepeat() {
        heldDirection = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Gamepad configuration

    /// Returns the connected GCController matching a device index, if still present.
    func controllerAt(index: Int) -> GCController? {
        guard devices.indices.contains(index) else { return nil }
        return controller(id: devices[index].id)
    }
    static func deviceID(_ controller: GCController) -> String { String(ObjectIdentifier(controller).hashValue) }
    func controller(id: String?) -> GCController? {
        connectedControllers.first { Self.deviceID($0) == id }
    }
    static func lightPresetIndex(_ color: GCColor) -> Int? {
        lightPresets.firstIndex { preset in
            abs(preset.color.red - color.red) < 0.02 && abs(preset.color.green - color.green) < 0.02 && abs(preset.color.blue - color.blue) < 0.02
        }
    }
    @discardableResult func setLightColor(_ color: GCColor, for controller: GCController) -> Bool {
        guard let light = controller.light, GCController.controllers().contains(where: { $0 === controller }) else { return false }
        light.color = color
        refreshStatus()
        return true
    }
    /// Keep the controller-created engine and player alive until playback finishes.
    func playHaptics(for controller: GCController) throws {
        guard let haptics = controller.haptics, !haptics.supportedLocalities.isEmpty,
              GCController.controllers().contains(where: { $0 === controller }) else { throw ControllerConfigurationError.hapticsUnavailable }
        let id = Self.deviceID(controller)
        let engine: CHHapticEngine
        if let existing = hapticEngines[id] { engine = existing }
        else {
            let locality = haptics.supportedLocalities.contains(.default) ? GCHapticsLocality.default : haptics.supportedLocalities.sorted { $0.rawValue < $1.rawValue }[0]
            guard let created = haptics.createEngine(withLocality: locality) else { throw ControllerConfigurationError.hapticsUnavailable }
            engine = created; hapticEngines[id] = engine
        }
        try hapticPlayers[id]?.stop(atTime: CHHapticTimeImmediate)
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
        ], relativeTime: 0, duration: 0.3)
        let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        hapticPlayers[id] = player
        try player.start(atTime: CHHapticTimeImmediate)
    }
    @discardableResult func setPlayerNumber(_ index: Int, for controller: GCController) -> Bool {
        guard (0...3).contains(index), let player = GCControllerPlayerIndex(rawValue: index),
              GCController.controllers().contains(where: { $0 === controller }) else { return false }
        controller.playerIndex = player
        refreshStatus()
        return true
    }
    func beginTesting() -> UUID {
        let token = UUID(); testSessions.insert(token)
        heldDirection = nil; repeatTimer?.invalidate()
        return token
    }
    func endTesting(_ token: UUID) {
        testSessions.remove(token)
        heldDirection = nil; repeatTimer?.invalidate()
    }
    /// Common light presets for quick configuration.
    static let lightPresets: [(name: String, color: GCColor)] = [
        ("Blue", GCColor(red: 0, green: 0.4, blue: 1)),
        ("Red", GCColor(red: 1, green: 0, blue: 0)),
        ("Green", GCColor(red: 0, green: 0.6, blue: 0)),
        ("Purple", GCColor(red: 0.6, green: 0, blue: 1)),
        ("Cyan", GCColor(red: 0, green: 0.8, blue: 0.8)),
        ("Yellow", GCColor(red: 1, green: 0.8, blue: 0)),
        ("White", GCColor(red: 1, green: 1, blue: 1)),
        ("Off", GCColor(red: 0, green: 0, blue: 0)),
    ]

    /// Common vibration patterns for testing.
    static let hapticPatterns: [String] = [
        "Pulse",
    ]
}

enum ControllerConfigurationError: LocalizedError {
    case hapticsUnavailable
    var errorDescription: String? { "Vibration is unavailable for this controller or is disabled in macOS controller settings." }
}
