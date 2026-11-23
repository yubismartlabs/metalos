import AppKit
import Combine
import GameController

struct ConsoleControllerStatus: Identifiable {
    let id: ObjectIdentifier
    let productName: String
    let batteryLevel: Float?
    let isCharging: Bool
}

enum ConsoleInputAction: Equatable {
    case move(ConsoleDirection)
    case confirm, back, options, tabLeft, tabRight, home, search

    var direction: ConsoleDirection? {
        if case .move(let direction) = self { return direction }
        return nil
    }
}

/// Unifies keyboard and extended gamepad input, including one shared hold-to-repeat clock.
@MainActor
final class ConsoleInputManager: ObservableObject {
    var onAction: ((ConsoleInputAction) -> Void)?
    var textEntryActive = false
    var globalSearchEntryActive = false
    var globalSearchCaretActive = false
    @Published private(set) var connectedControllers: [ConsoleControllerStatus] = []
    var stickDeadzone: Float = 0.35
    var holdRepeatDelay: TimeInterval = 0.32
    var holdRepeatInterval: TimeInterval = 0.102

    private enum HoldSource: Hashable {
        case key(UInt16)
        case dpad(String, ConsoleDirection)
        case stick(String)
    }

    private struct PadBinding {
        let controller: GCController
        let pad: GCExtendedGamepad
    }

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pads: [ObjectIdentifier: PadBinding] = [:]
    private var heldDirections: [HoldSource: ConsoleDirection] = [:]
    private var holdOrder: [HoldSource] = []
    private var stickDirections: [String: ConsoleDirection] = [:]
    private var activeHold: HoldSource?
    private var activeDirection: ConsoleDirection?
    private var repeatTimer: Timer?
    private var batteryRefreshTimer: Timer?
    private var foregroundRoutingEnabled = true
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        GCController.shouldMonitorBackgroundEvents = true
        observers = [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshControllers() }
            }
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyUp(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isConsoleWindow(event.window) { self.revealCursor() }
            return event
        }
        DispatchQueue.main.async { NSApp.keyWindow?.acceptsMouseMovedEvents = true }
        refreshControllers()
        batteryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshControllerStatuses() }
        }
    }

    func setForegroundRoutingEnabled(_ enabled: Bool) {
        foregroundRoutingEnabled = enabled
        if enabled { refreshControllers() }
        else { ConsoleCursorManager.shared.unhide() }
    }

    func refreshConnectedControllers() { refreshControllers() }
    func dispatchControllerHome() { emit(.home) }
    func dispatchControllerAction(_ action: ConsoleInputAction) { emit(action) }

    func stop() {
        guard started else { return }
        started = false
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyDownMonitor = nil
        keyUpMonitor = nil
        mouseMonitor = nil
        batteryRefreshTimer?.invalidate()
        batteryRefreshTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        pads.values.forEach(unbind)
        pads.removeAll()
        clearHeldDirections()
        revealCursor()
    }

    private func refreshControllers() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        let connectedIDs = Set(controllers.map(ObjectIdentifier.init))
        for (id, binding) in pads where !connectedIDs.contains(id) { unbind(binding) }
        pads = pads.filter { connectedIDs.contains($0.key) }
        for controller in controllers {
            let id = ObjectIdentifier(controller)
            guard pads[id] == nil, let pad = controller.extendedGamepad else { continue }
            padBindings(controller, pad: pad, id: id)
        }
        refreshControllerStatuses()
    }

    private func padBindings(_ controller: GCController, pad: GCExtendedGamepad, id: ObjectIdentifier) {
        let controllerID = String(describing: id)
        controller.handlerQueue = .main
        pads[id] = PadBinding(controller: controller, pad: pad)
        pad.buttonHome?.preferredSystemGestureState = .disabled

        let dpadInputs: [(GCControllerButtonInput, ConsoleDirection)] = [
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right)
        ]
        for (button, direction) in dpadInputs {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor in self?.setHeld(.dpad(controllerID, direction), direction: pressed ? direction : nil) }
            }
        }

        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in self?.updateStick(controllerID, x: x, y: y) }
        }

        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.confirm) } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.back) } }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.options) } }
        }
        pad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.options) } }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.tabLeft) } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.emit(.tabRight) } }
        }
        pad.buttonHome?.pressedChangedHandler = { _, _, pressed in
            if pressed { Task { @MainActor in ConsoleShellCoordinator.shared.controllerHomePressed() } }
        }
    }

    private func unbind(_ binding: PadBinding) {
        let pad = binding.pad
        for button in [pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right] { button.pressedChangedHandler = nil }
        pad.leftThumbstick.valueChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil
        pad.buttonMenu.pressedChangedHandler = nil
        pad.buttonOptions?.pressedChangedHandler = nil
        pad.leftShoulder.pressedChangedHandler = nil
        pad.rightShoulder.pressedChangedHandler = nil
        pad.buttonHome?.pressedChangedHandler = nil
    }

    private func refreshControllerStatuses() {
        connectedControllers = pads.values.map { binding in
            let battery = binding.controller.battery
            let level = battery?.batteryLevel ?? -1
            return ConsoleControllerStatus(
                id: ObjectIdentifier(binding.controller),
                productName: binding.controller.vendorName ?? "Game Controller",
                batteryLevel: level >= 0 ? level : nil,
                isCharging: battery?.batteryState == .charging
            )
        }.sorted { $0.productName.localizedCaseInsensitiveCompare($1.productName) == .orderedAscending }
    }

    private func updateStick(_ id: String, x: Float, y: Float) {
        let prior = stickDirections[id]
        let magnitude = max(abs(x), abs(y))
        let deadzone = prior == nil ? stickDeadzone : max(0.12, stickDeadzone - 0.07)
        let next: ConsoleDirection?
        if magnitude < deadzone {
            next = nil
        } else if abs(x) > abs(y) {
            next = x > 0 ? .right : .left
        } else {
            next = y > 0 ? .up : .down
        }
        stickDirections[id] = next
        setHeld(.stick(id), direction: next)
    }

    private func setHeld(_ source: HoldSource, direction: ConsoleDirection?) {
        if let direction {
            guard heldDirections[source] != direction else { return }
            heldDirections[source] = direction
            holdOrder.removeAll { $0 == source }
            holdOrder.append(source)
            guard let activeHold, heldDirections[activeHold] == direction else {
                beginRepeating(source, direction: direction)
                return
            }
            return
        }

        heldDirections.removeValue(forKey: source)
        holdOrder.removeAll { $0 == source }
        guard source == activeHold else { return }
        guard let nextSource = holdOrder.last, let nextDirection = heldDirections[nextSource] else {
            clearHeldDirections()
            return
        }
        if nextDirection != activeDirection { beginRepeating(nextSource, direction: nextDirection) }
        else { activeHold = nextSource }
    }

    private func beginRepeating(_ source: HoldSource, direction: ConsoleDirection) {
        activeHold = source
        activeDirection = direction
        repeatTimer?.invalidate()
        emit(.move(direction))
        repeatTimer = Timer.scheduledTimer(withTimeInterval: holdRepeatDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeDirection == direction else { return }
                self.emit(.move(direction))
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.holdRepeatInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.activeDirection == direction else { return }
                        self.emit(.move(direction))
                    }
                }
            }
        }
    }

    private func clearHeldDirections() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldDirections.removeAll()
        holdOrder.removeAll()
        stickDirections.removeAll()
        activeHold = nil
        activeDirection = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if NSApp.isActive, event.keyCode == 12,
           event.modifierFlags.intersection([.command, .option]).contains([.command, .option]) {
            ConsoleShellCoordinator.shared.exitToDesktop()
            return nil
        }
        guard isConsoleWindow(event.window) else { return event }
        if globalSearchEntryActive {
            if event.keyCode == 53 { if !event.isARepeat { emit(.back) }; return nil }
            if event.keyCode == 51 { return event }
            if event.keyCode == 36 || event.keyCode == 76 { if !event.isARepeat { emit(.confirm) }; return nil }
            if [123, 124, 125, 126].contains(event.keyCode) {
                if globalSearchCaretActive && (event.keyCode == 123 || event.keyCode == 124) { return event }
                if let direction = keyboardDirection(event) { setHeld(.key(event.keyCode), direction: direction) }
                return nil
            }
            return event
        }
        if textEntryActive {
            if event.keyCode == 53 { if !event.isARepeat { emit(.back) }; return nil }
            if event.keyCode == 36 || event.keyCode == 76 { if !event.isARepeat { emit(.confirm) }; return nil }
            if event.keyCode == 48 { return nil }
            return event
        }
        if event.keyCode == 48 {
            if !event.isARepeat { emit(.home) }
            return nil // Tab is the console Home shortcut, never desktop focus traversal.
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }

        if let direction = keyboardDirection(event) {
            setHeld(.key(event.keyCode), direction: direction)
            return nil
        }
        guard !event.isARepeat, let action = keyboardAction(event) else { return keyboardAction(event) == nil ? event : nil }
        emit(action)
        return nil
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard isConsoleWindow(event.window), let direction = keyboardDirection(event) else { return event }
        setHeld(.key(event.keyCode), direction: nil)
        _ = direction
        return nil
    }

    private func keyboardDirection(_ event: NSEvent) -> ConsoleDirection? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        return switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": .left
        case "d": .right
        case "s": .down
        case "w": .up
        default: nil
        }
    }

    private func keyboardAction(_ event: NSEvent) -> ConsoleInputAction? {
        switch event.keyCode {
        case 36, 76, 49: return .confirm
        case 53, 51: return .back
        case 8, 122: return .home // C and F1
        case 12, 33: return .tabLeft // Q and [
        case 14, 30: return .tabRight // E and ]
        case 46, 31: return .options // M and O
        case 44: return .search // /
        default: break
        }
        return switch event.charactersIgnoringModifiers?.lowercased() {
        case "q", "[": .tabLeft
        case "e", "]": .tabRight
        case "m", "o": .options
        case "c": .home
        case "/": .search
        default: nil
        }
    }

    private func isConsoleWindow(_ eventWindow: NSWindow?) -> Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow else { return false }
        return eventWindow == nil || eventWindow === window
    }

    private func emit(_ action: ConsoleInputAction) {
        guard foregroundRoutingEnabled, NSApp.isActive else { return }
        hideCursor()
        onAction?(action)
    }

    private func hideCursor() {
        ConsoleCursorManager.shared.hide()
    }

    private func revealCursor() {
        ConsoleCursorManager.shared.unhide()
    }
}

enum ConsoleLauncherTab: Equatable { case games, media }
enum ConsoleMediaHeroAction: Equatable { case open, options }
enum ConsoleMediaModal: Equatable { case localVideoPlayer, consoleWebPlayer, appManager }
enum ConsoleTopBarItem: CaseIterable, Equatable { case games, media, search, settings, fullscreen, profile }
enum ConsoleHeroAction: Equatable { case play, options }
enum ConsoleControlCenterItem: Int, CaseIterable, Equatable {
    case home, network, sound, accessories, power

    var title: String {
        switch self {
        case .home: "Home"
        case .network: "Network"
        case .sound: "Sound"
        case .accessories: "Accessories"
        case .power: "Power"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .network: "wifi"
        case .sound: "speaker.wave.2.fill"
        case .accessories: "gamecontroller.fill"
        case .power: "power"
        }
    }
}
enum ConsoleControlCard: Equatable { case network, sound, accessories, power }
enum ConsoleLibraryTab: Int, CaseIterable, Equatable {
    case installed, favorites, collections

    var title: String {
        switch self {
        case .installed: "Installed"
        case .favorites: "Favorites"
        case .collections: "Collections"
        }
    }
}
enum ConsoleLibraryFocusRegion: Equatable { case tabs, utilities, grid, searchEntry, menu }
enum ConsoleLibraryMenu: Equatable { case sort, gameOptions, collectionPicker }
enum ConsoleLibrarySort: Int, CaseIterable, Equatable {
    case recentlyPlayed, aToZ, zToA, playtime

    var title: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .aToZ: "A–Z"
        case .zToA: "Z–A"
        case .playtime: "Playtime"
        }
    }
}
enum ConsoleSettingsCategory: Int, CaseIterable, Equatable {
    case display, audio, controllers, gamePaths, theme

    var title: String {
        switch self {
        case .display: "Display"
        case .audio: "Audio"
        case .controllers: "Controllers"
        case .gamePaths: "Game Paths"
        case .theme: "Theme"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .audio: "speaker.wave.2.fill"
        case .controllers: "gamecontroller.fill"
        case .gamePaths: "folder.fill"
        case .theme: "circle.lefthalf.filled"
        }
    }

    var subtitle: String {
        switch self {
        case .display: "Tune the canvas and motion of your console."
        case .audio: "Shape the sounds that accompany your play."
        case .controllers: "Adjust prompts and the feel of navigation."
        case .gamePaths: "Choose where MetalOS looks for your games."
        case .theme: "Personalize focus, glass, and system time."
        }
    }
}
enum ConsoleSettingsZone: Equatable { case categoryRail, detailPane }
enum ConsoleSettingInteraction: Equatable { case toggle, stepper, selector, action, information }
enum ConsoleFocusTarget: Equatable {
    case topBar(ConsoleTopBarItem)
    case gameRibbon(Int)
    case heroActions(ConsoleHeroAction)
    case belowFold(row: Int, index: Int)
    case mediaRibbon(Int)
    case mediaHeroActions(ConsoleMediaHeroAction)
    case mediaBelowFold(row: Int, index: Int)
}

enum ConsoleGlobalSearchRegion: Equatable { case searchBar, virtualKeyboard, filters, results }

enum ConsoleOverviewModal: Equatable {
    case trailer(GameDBVideo)
    case screenshot(title: String, paths: [String], index: Int)
    case summary(title: String, summary: String, storyline: String?)
}

/// Deterministic spatial focus graph with remembered entry points for each console zone.
@MainActor
final class FocusCoordinator: ObservableObject {
    @Published private(set) var focusTarget: ConsoleFocusTarget = .gameRibbon(0)
    @Published private(set) var selectedTab: ConsoleLauncherTab = .games
    @Published private(set) var selectedGameIndex = 0
    @Published private(set) var selectedMediaIndex = 0
    @Published private(set) var showingBelowFold = false
    @Published private(set) var belowFoldRowCounts = [3, 1, 1]
    @Published private(set) var activeOverviewModal: ConsoleOverviewModal?
    @Published private(set) var showingMediaBelowFold = false
    @Published private(set) var mediaBelowFoldRowCounts = [4, 4]
    @Published private(set) var activeMediaModal: ConsoleMediaModal?
    @Published private(set) var isControlCenterPresented = false
    @Published private(set) var selectedControlCenterItem: ConsoleControlCenterItem = .home
    @Published private(set) var activeControlCard: ConsoleControlCard?
    @Published private(set) var controlCardItemIndex = 0
    @Published private(set) var quickVolume = 0.62
    @Published private(set) var selectedAudioOutputIndex = 0
    @Published private(set) var connectedControllerCount = 0
    @Published private(set) var isLibraryPresented = false
    @Published private(set) var libraryTab: ConsoleLibraryTab = .installed
    @Published private(set) var libraryFocusRegion: ConsoleLibraryFocusRegion = .grid
    @Published private(set) var libraryFocusIndex = 0
    @Published private(set) var libraryGridCount = 24
    @Published private(set) var libraryGridColumns = 5
    @Published private(set) var libraryMenu: ConsoleLibraryMenu?
    @Published private(set) var libraryMenuIndex = 0
    @Published private(set) var libraryMenuItemCount = 4
    @Published private(set) var librarySort: ConsoleLibrarySort = .recentlyPlayed
    @Published private(set) var activeLibraryCollectionID: String?
    @Published private(set) var libraryUtilityIndex = 0
    @Published private(set) var isLibrarySearchActive = false
    @Published private(set) var isCustomizingLibraryHero = false
    @Published private(set) var isSettingsPresented = false
    @Published private(set) var settingsCategory: ConsoleSettingsCategory = .display
    @Published private(set) var settingsZone: ConsoleSettingsZone = .categoryRail
    @Published private(set) var settingsItemIndex = 0
    @Published private(set) var settingsSelectorOpen = false
    @Published private(set) var settingsSelectorIndex = 0
    @Published private(set) var activeExternalAppTitle: String?
    @Published private(set) var isGlobalSearchPresented = false
    @Published private(set) var globalSearchRegion: ConsoleGlobalSearchRegion = .searchBar
    @Published private(set) var globalSearchKeyboardIndex = 0
    @Published private(set) var globalSearchFilterIndex = 0
    @Published private(set) var globalSearchResultIndex = 0
    @Published private(set) var globalSearchResultCount = 0
    @Published private(set) var isGlobalSearchKeyboardVisible = false

    private var settingsInteractions: [ConsoleSettingInteraction] = []
    private var settingsOptionCount = 1

    private var gameCount: Int
    private var mediaCount = 8
    private var lastTopBarItem: ConsoleTopBarItem = .games
    private var lastFocusedGameIndex = 0
    private var lastFocusedMediaIndex = 0
    private var lastHeroAction: ConsoleHeroAction = .play
    private var lastBelowFoldIndices = [0, 0, 0]
    private var lastMediaHeroAction: ConsoleMediaHeroAction = .open
    private var lastMediaBelowFoldIndices = [0, 0]

    var onFocusChanged: ((ConsoleFocusTarget) -> Void)?
    var onTabSwitch: (() -> Void)?
    var onBoundaryBump: ((ConsoleDirection) -> Void)?
    var onConfirm: ((ConsoleFocusTarget) -> Void)?
    var onBack: (() -> Void)?
    var onOptions: (() -> Void)?
    var onHome: (() -> Void)?
    var onControlCenterChanged: ((Bool) -> Void)?
    var onControlCardChanged: ((Bool) -> Void)?
    var onControlCenterFocusMove: (() -> Void)?
    var onControlCenterBack: (() -> Void)?
    var onVolumeChanged: ((Double) -> Void)?
    var onAudioOutputChanged: ((Int) -> Void)?
    var onControlCardConfirm: ((ConsoleControlCard, Int) -> Void)?
    var onPowerAction: ((Int) -> Void)?
    var onLibraryStateChanged: ((Bool) -> Void)?
    var onLibraryFocusMove: ((Int) -> Void)?
    var onLibraryTabChanged: ((ConsoleLibraryTab) -> Void)?
    var onLibrarySearchChanged: ((Bool) -> Void)?
    var onLibrarySearchBack: (() -> Bool)?
    var onLibraryConfirm: ((Int) -> Void)?
    var onLibraryMenuAction: ((ConsoleLibraryMenu, Int) -> Void)?
    var onLibraryArtworkStep: ((Int) -> Void)?
    var onLibraryHeroCustomizationFinished: (() -> Void)?
    var onOverviewModalChanged: ((Bool) -> Void)?
    var onOverviewModalFocusMove: (() -> Void)?
    var onMediaConfirm: ((ConsoleFocusTarget) -> Void)?
    var onMediaModalAction: ((ConsoleInputAction) -> Void)?
    var onMediaModalChanged: ((Bool) -> Void)?
    var onMediaModalFocusMove: (() -> Void)?
    var onSettingsStateChanged: ((Bool) -> Void)?
    var onSettingsFocusMove: (() -> Void)?
    var onSettingsConfirm: ((Int) -> Void)?
    var onSettingsAdjust: ((Int, Int) -> Void)?
    var onSettingsSelect: ((Int, Int) -> Void)?
    var onGlobalSearchStateChanged: ((Bool) -> Void)?
    var onGlobalSearchFocusMove: (() -> Void)?
    var onGlobalSearchFilterChanged: ((Int) -> Void)?
    var onGlobalSearchKey: ((String) -> Void)?
    var onGlobalSearchConfirm: ((Int) -> Void)?
    var onGlobalSearchBack: (() -> Bool)?

    init(gameCount: Int) { self.gameCount = max(0, gameCount) }

    func synchronizeGameCount(_ count: Int) {
        gameCount = max(0, count)
        lastFocusedGameIndex = min(lastFocusedGameIndex, max(0, gameCount - 1))
        selectedGameIndex = lastFocusedGameIndex
        if case .gameRibbon(let index) = focusTarget, index > gameCount {
            focus(.gameRibbon(gameCount))
        }
    }

    func synchronizeBelowFoldRows(cardCounts: [Int]) {
        belowFoldRowCounts = cardCounts.map { max(1, $0) }
        if belowFoldRowCounts.isEmpty { belowFoldRowCounts = [1] }
        if lastBelowFoldIndices.count != belowFoldRowCounts.count {
            lastBelowFoldIndices = Array(lastBelowFoldIndices.prefix(belowFoldRowCounts.count))
            while lastBelowFoldIndices.count < belowFoldRowCounts.count { lastBelowFoldIndices.append(0) }
        }
        for row in lastBelowFoldIndices.indices {
            lastBelowFoldIndices[row] = min(lastBelowFoldIndices[row], belowFoldRowCounts[row] - 1)
        }
        if case .belowFold(let row, _) = focusTarget {
            let safeRow = min(row, belowFoldRowCounts.count - 1)
            focus(.belowFold(row: safeRow, index: lastBelowFoldIndices[safeRow]))
        }
    }

    func synchronizeMediaCount(_ count: Int) {
        mediaCount = max(0, count)
        lastFocusedMediaIndex = min(lastFocusedMediaIndex, max(0, mediaCount - 1))
        selectedMediaIndex = lastFocusedMediaIndex
        if case .mediaRibbon(let index) = focusTarget, index >= mediaCount {
            focus(.mediaRibbon(max(0, mediaCount - 1)))
        }
    }

    func synchronizeMediaBelowFoldRows(cardCounts: [Int]) {
        mediaBelowFoldRowCounts = cardCounts.map { max(1, $0) }
        if mediaBelowFoldRowCounts.isEmpty { mediaBelowFoldRowCounts = [1] }
        if lastMediaBelowFoldIndices.count != mediaBelowFoldRowCounts.count {
            lastMediaBelowFoldIndices = Array(lastMediaBelowFoldIndices.prefix(mediaBelowFoldRowCounts.count))
            while lastMediaBelowFoldIndices.count < mediaBelowFoldRowCounts.count { lastMediaBelowFoldIndices.append(0) }
        }
        for row in lastMediaBelowFoldIndices.indices {
            lastMediaBelowFoldIndices[row] = min(lastMediaBelowFoldIndices[row], mediaBelowFoldRowCounts[row] - 1)
        }
        if case .mediaBelowFold(let row, _) = focusTarget {
            let safeRow = min(row, mediaBelowFoldRowCounts.count - 1)
            focus(.mediaBelowFold(row: safeRow, index: lastMediaBelowFoldIndices[safeRow]))
        }
    }

    func presentMediaModal(_ modal: ConsoleMediaModal) {
        guard activeMediaModal == nil else { return }
        activeMediaModal = modal
        onMediaModalChanged?(true)
    }

    func dismissMediaModal() {
        guard activeMediaModal != nil else { return }
        activeMediaModal = nil
        onMediaModalChanged?(false)
    }

    func presentOverviewModal(_ modal: ConsoleOverviewModal) {
        guard activeOverviewModal == nil else { return }
        activeOverviewModal = modal
        onOverviewModalChanged?(true)
    }

    private func dismissOverviewModal() {
        guard activeOverviewModal != nil else { return }
        activeOverviewModal = nil
        onOverviewModalChanged?(false)
    }

    func focus(_ target: ConsoleFocusTarget) {
        guard target != focusTarget else { return }
        let previousTab = selectedTab
        focusTarget = target
        switch target {
        case .topBar(let item):
            lastTopBarItem = item
            if item == .games { selectedTab = .games }
            if item == .media { selectedTab = .media }
            showingBelowFold = false
            showingMediaBelowFold = false
        case .gameRibbon(let index):
            showingBelowFold = false
            if index < gameCount {
                lastFocusedGameIndex = max(0, index)
                selectedGameIndex = lastFocusedGameIndex
                selectedTab = .games
            }
            showingMediaBelowFold = false
        case .heroActions(let action):
            lastHeroAction = action
            selectedTab = .games
            showingBelowFold = false
            showingMediaBelowFold = false
        case .belowFold(let row, let index):
            let row = min(max(0, row), belowFoldRowCounts.count - 1)
            let index = min(max(0, index), max(0, belowFoldRowCounts[row] - 1))
            lastBelowFoldIndices[row] = index
            showingBelowFold = true
            selectedTab = .games
            showingMediaBelowFold = false
        case .mediaRibbon(let index):
            if index < mediaCount {
                lastFocusedMediaIndex = max(0, index)
                selectedMediaIndex = lastFocusedMediaIndex
            }
            selectedTab = .media
            showingBelowFold = false
            showingMediaBelowFold = false
        case .mediaHeroActions(let action):
            lastMediaHeroAction = action
            selectedTab = .media
            showingBelowFold = false
            showingMediaBelowFold = false
        case .mediaBelowFold(let row, let index):
            let safeRow = min(max(0, row), mediaBelowFoldRowCounts.count - 1)
            let safeIndex = min(max(0, index), mediaBelowFoldRowCounts[safeRow] - 1)
            lastMediaBelowFoldIndices[safeRow] = safeIndex
            selectedTab = .media
            showingBelowFold = false
            showingMediaBelowFold = true
        }
        if selectedTab != previousTab { onTabSwitch?() }
        onFocusChanged?(target)
    }

    func selectTab(_ tab: ConsoleLauncherTab) {
        let changed = selectedTab != tab
        if changed { onTabSwitch?() }
        selectedTab = tab
        switch tab {
        case .games:
            if case .topBar = focusTarget { focus(.topBar(.games)) }
            else { focus(.gameRibbon(lastFocusedGameIndex)) }
        case .media:
            if case .topBar = focusTarget { focus(.topBar(.media)) }
            else { focus(.mediaRibbon(lastFocusedMediaIndex)) }
        }
    }

    func handle(_ action: ConsoleInputAction) {
        if isGlobalSearchPresented {
            handleGlobalSearch(action)
            return
        }
        if activeMediaModal != nil {
            onMediaModalAction?(action)
            return
        }
        if activeOverviewModal != nil {
            handleOverviewModal(action)
            return
        }
        if isSettingsPresented {
            handleSettings(action)
            return
        }
        if isControlCenterPresented {
            handleControlCenter(action)
            return
        }
        if isLibraryPresented {
            handleLibrary(action)
            return
        }
        switch action {
        case .move(.up): moveUp()
        case .move(.down): moveDown()
        case .move(.left): moveHorizontally(-1)
        case .move(.right): moveHorizontally(1)
        case .confirm:
            if selectedTab == .media { onMediaConfirm?(focusTarget) }
            else { onConfirm?(focusTarget) }
        case .back: moveBack()
        case .options:
            if selectedTab == .media { onMediaConfirm?(.mediaHeroActions(.options)) }
            else { onOptions?() }
        case .tabLeft, .tabRight: selectTab(selectedTab == .games ? .media : .games)
        case .home: openControlCenter()
        case .search: openGlobalSearch()
        }
    }

    func openGlobalSearch() {
        guard !isGlobalSearchPresented, !isControlCenterPresented, !isSettingsPresented,
              !isLibraryPresented, activeMediaModal == nil, activeOverviewModal == nil else { return }
        isGlobalSearchPresented = true
        globalSearchRegion = .searchBar
        globalSearchKeyboardIndex = 0
        globalSearchFilterIndex = 0
        globalSearchResultIndex = 0
        isGlobalSearchKeyboardVisible = connectedControllerCount > 0
        onGlobalSearchStateChanged?(true)
        onGlobalSearchFocusMove?()
        UISoundManager.playOverlayOpen()
    }

    func closeGlobalSearch() {
        guard isGlobalSearchPresented else { return }
        isGlobalSearchPresented = false
        globalSearchRegion = .searchBar
        onGlobalSearchStateChanged?(false)
        onGlobalSearchFocusMove?()
        UISoundManager.playOverlayClose()
    }

    func setGlobalSearchResultCount(_ count: Int) {
        globalSearchResultCount = max(0, count)
        globalSearchResultIndex = min(globalSearchResultIndex, max(0, globalSearchResultCount - 1))
    }

    func setGlobalSearchKeyboardVisible(_ visible: Bool) {
        isGlobalSearchKeyboardVisible = visible
        if !visible && globalSearchRegion == .virtualKeyboard { globalSearchRegion = .searchBar }
        onGlobalSearchFocusMove?()
    }

    func chooseGlobalSearchFilter(_ index: Int) {
        let next = min(3, max(0, index))
        let filterChanged = globalSearchFilterIndex != next
        globalSearchFilterIndex = next
        globalSearchResultIndex = 0
        globalSearchRegion = .filters
        if filterChanged { onGlobalSearchFilterChanged?(next) }
        onGlobalSearchFocusMove?()
    }

    func focusGlobalSearchResults() { setGlobalSearchRegion(.results) }
    func focusGlobalSearchBar() { setGlobalSearchRegion(.searchBar) }
    func focusGlobalSearchKeyboard() { setGlobalSearchRegion(.virtualKeyboard) }

    private func handleGlobalSearch(_ action: ConsoleInputAction) {
        switch action {
        case .move(.left): moveGlobalSearchHorizontal(-1)
        case .move(.right): moveGlobalSearchHorizontal(1)
        case .move(.up):
            switch globalSearchRegion {
            case .searchBar: onBoundaryBump?(.up)
            case .virtualKeyboard:
                if globalSearchKeyboardIndex >= 10 { globalSearchKeyboardIndex -= 10; onGlobalSearchFocusMove?() }
                else { setGlobalSearchRegion(.searchBar) }
            case .filters: setGlobalSearchRegion(isGlobalSearchKeyboardVisible ? .virtualKeyboard : .searchBar)
            case .results: setGlobalSearchRegion(.filters)
            }
        case .move(.down):
            switch globalSearchRegion {
            case .searchBar: setGlobalSearchRegion(isGlobalSearchKeyboardVisible ? .virtualKeyboard : .filters)
            case .virtualKeyboard:
                if globalSearchKeyboardIndex + 10 < Self.searchKeyboardKeys.count { globalSearchKeyboardIndex += 10; onGlobalSearchFocusMove?() }
                else { setGlobalSearchRegion(.filters) }
            case .filters: setGlobalSearchRegion(.results)
            case .results: onBoundaryBump?(.down)
            }
        case .confirm:
            switch globalSearchRegion {
            case .searchBar: setGlobalSearchRegion(isGlobalSearchKeyboardVisible ? .virtualKeyboard : .filters)
            case .virtualKeyboard:
                if globalSearchKeyboardIndex == Self.searchKeyboardKeys.count - 1 { setGlobalSearchRegion(.results) }
                else { onGlobalSearchKey?(Self.searchKeyboardKeys[globalSearchKeyboardIndex]) }
                UISoundManager.playConfirm()
            case .filters: setGlobalSearchRegion(.results)
            case .results:
                guard globalSearchResultCount > 0 else { onBoundaryBump?(.right); return }
                onGlobalSearchConfirm?(globalSearchResultIndex)
                UISoundManager.playConfirm()
            }
        case .back:
            if globalSearchRegion != .searchBar { setGlobalSearchRegion(.searchBar) }
            else if onGlobalSearchBack?() != true { closeGlobalSearch() }
            else { UISoundManager.playBack() }
        case .tabLeft: onGlobalSearchKey?("Backspace"); UISoundManager.playSliderTick()
        case .tabRight: onGlobalSearchKey?("Space"); UISoundManager.playSliderTick()
        case .options, .home, .search: break
        }
    }

    private static let searchKeyboardKeys = ["Q","W","E","R","T","Y","U","I","O","P","A","S","D","F","G","H","J","K","L","Z","X","C","V","B","N","M","Space","Backspace","Clear","Done"]

    private func moveGlobalSearchHorizontal(_ amount: Int) {
        switch globalSearchRegion {
        case .searchBar: onBoundaryBump?(amount < 0 ? .left : .right)
        case .virtualKeyboard:
            let next = globalSearchKeyboardIndex + amount
            guard Self.searchKeyboardKeys.indices.contains(next) else { onBoundaryBump?(amount < 0 ? .left : .right); return }
            globalSearchKeyboardIndex = next
            onGlobalSearchFocusMove?()
        case .filters: chooseGlobalSearchFilter(globalSearchFilterIndex + amount)
        case .results:
            let next = globalSearchResultIndex + amount
            guard (0..<globalSearchResultCount).contains(next) else { onBoundaryBump?(amount < 0 ? .left : .right); return }
            globalSearchResultIndex = next
            onGlobalSearchFocusMove?()
        }
    }

    private func setGlobalSearchRegion(_ region: ConsoleGlobalSearchRegion) {
        globalSearchRegion = region
        onGlobalSearchFocusMove?()
    }

    private func handleOverviewModal(_ action: ConsoleInputAction) {
        switch action {
        case .back, .confirm:
            dismissOverviewModal()
        case .move(.left), .move(.right):
            guard case let .screenshot(title, paths, index) = activeOverviewModal, !paths.isEmpty else { return }
            let delta = action == .move(.left) ? -1 : 1
            let next = (index + delta + paths.count) % paths.count
            activeOverviewModal = .screenshot(title: title, paths: paths, index: next)
            onOverviewModalFocusMove?()
        case .move(.up), .move(.down): break
        case .options, .tabLeft, .tabRight, .home, .search: break
        }
    }

    func openSettings() {
        guard !isSettingsPresented else { return }
        isSettingsPresented = true
        settingsCategory = .display
        settingsZone = .categoryRail
        settingsItemIndex = 0
        settingsSelectorOpen = false
        onSettingsStateChanged?(true)
        onSettingsFocusMove?()
    }

    func closeSettings() {
        guard isSettingsPresented else { return }
        isSettingsPresented = false
        settingsSelectorOpen = false
        settingsZone = .categoryRail
        onSettingsStateChanged?(false)
    }

    func synchronizeSettings(items: [ConsoleSettingInteraction], selectorOptions: [String] = []) {
        settingsInteractions = items
        settingsOptionCount = max(1, selectorOptions.count)
        settingsItemIndex = min(settingsItemIndex, max(0, items.count - 1))
        settingsSelectorIndex = min(settingsSelectorIndex, max(0, selectorOptions.count - 1))
    }

    func openSettingsSelector(selectedIndex: Int, optionCount: Int) {
        settingsOptionCount = max(1, optionCount)
        settingsSelectorIndex = min(max(0, selectedIndex), settingsOptionCount - 1)
        settingsSelectorOpen = true
        onSettingsFocusMove?()
    }

    func enterSettingsDetail(at index: Int = 0) {
        settingsZone = .detailPane
        settingsItemIndex = min(max(0, index), max(0, settingsInteractions.count - 1))
        onSettingsFocusMove?()
    }

    func closeSettingsSelector() {
        guard settingsSelectorOpen else { return }
        settingsSelectorOpen = false
        onSettingsFocusMove?()
    }

    func chooseSettingsCategory(_ category: ConsoleSettingsCategory) {
        guard settingsCategory != category else { return }
        settingsCategory = category
        settingsZone = .categoryRail
        settingsItemIndex = 0
        settingsSelectorOpen = false
        onSettingsFocusMove?()
    }

    private func handleSettings(_ action: ConsoleInputAction) {
        switch action {
        case .move(.up):
            if settingsSelectorOpen {
                settingsSelectorIndex = max(0, settingsSelectorIndex - 1)
                onSettingsFocusMove?()
            } else if settingsZone == .categoryRail {
                let next = max(0, settingsCategory.rawValue - 1)
                if let category = ConsoleSettingsCategory(rawValue: next), category != settingsCategory {
                    settingsCategory = category
                    settingsItemIndex = 0
                    onSettingsFocusMove?()
                } else { onBoundaryBump?(.up) }
            } else {
                let next = settingsItemIndex - 1
                guard next >= 0 else { onBoundaryBump?(.up); return }
                settingsItemIndex = next
                onSettingsFocusMove?()
            }
        case .move(.down):
            if settingsSelectorOpen {
                let next = settingsSelectorIndex + 1
                guard next < settingsSelectorCount else { onBoundaryBump?(.down); return }
                settingsSelectorIndex = next
                onSettingsFocusMove?()
            } else if settingsZone == .categoryRail {
                let next = min(ConsoleSettingsCategory.allCases.count - 1, settingsCategory.rawValue + 1)
                if let category = ConsoleSettingsCategory(rawValue: next), category != settingsCategory {
                    settingsCategory = category
                    settingsItemIndex = 0
                    onSettingsFocusMove?()
                } else { onBoundaryBump?(.down) }
            } else {
                let next = settingsItemIndex + 1
                guard next < settingsInteractions.count else { onBoundaryBump?(.down); return }
                settingsItemIndex = next
                onSettingsFocusMove?()
            }
        case .move(.left):
            if settingsSelectorOpen {
                onBoundaryBump?(.left)
            } else if settingsZone == .detailPane {
                if settingsInteractions.indices.contains(settingsItemIndex), settingsInteractions[settingsItemIndex] == .stepper {
                    onSettingsAdjust?(settingsItemIndex, -1)
                } else {
                    settingsZone = .categoryRail
                    onSettingsFocusMove?()
                }
            } else { onBoundaryBump?(.left) }
        case .move(.right):
            if settingsSelectorOpen { onBoundaryBump?(.right) }
            else if settingsZone == .categoryRail {
                settingsZone = .detailPane
                settingsItemIndex = 0
                onSettingsFocusMove?()
            } else if settingsInteractions.indices.contains(settingsItemIndex), settingsInteractions[settingsItemIndex] == .stepper {
                onSettingsAdjust?(settingsItemIndex, 1)
            } else { onBoundaryBump?(.right) }
        case .confirm:
            if settingsSelectorOpen {
                onSettingsSelect?(settingsItemIndex, settingsSelectorIndex)
                settingsSelectorOpen = false
                onSettingsFocusMove?()
            } else if settingsZone == .categoryRail {
                settingsZone = .detailPane
                settingsItemIndex = 0
                onSettingsFocusMove?()
            } else { onSettingsConfirm?(settingsItemIndex) }
        case .back:
            onBack?()
            if settingsSelectorOpen {
                settingsSelectorOpen = false
                onSettingsFocusMove?()
            } else if settingsZone == .detailPane {
                settingsZone = .categoryRail
                onSettingsFocusMove?()
            } else { closeSettings() }
        case .options, .tabLeft, .tabRight, .home, .search: break
        }
    }

    private var settingsSelectorCount: Int { settingsOptionCount }

    func openLibrary(itemCount: Int = 24, columns: Int = 5) {
        guard !isLibraryPresented else { return }
        isLibraryPresented = true
        libraryTab = .installed
        libraryFocusRegion = .grid
        libraryFocusIndex = 0
        libraryGridColumns = max(1, columns)
        libraryGridCount = max(1, itemCount)
        libraryMenu = nil
        activeLibraryCollectionID = nil
        isLibrarySearchActive = false
        onLibraryStateChanged?(true)
        onLibraryTabChanged?(libraryTab)
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func closeLibrary() {
        guard isLibraryPresented else { return }
        isLibraryPresented = false
        libraryMenu = nil
        activeLibraryCollectionID = nil
        isLibrarySearchActive = false
        libraryFocusRegion = .grid
        onLibrarySearchChanged?(false)
        onLibraryStateChanged?(false)
    }

    func synchronizeLibraryGrid(itemCount: Int, columns: Int) {
        libraryGridCount = max(1, itemCount)
        libraryGridColumns = max(1, columns)
        let clamped = min(libraryFocusIndex, libraryGridCount - 1)
        if clamped != libraryFocusIndex {
            libraryFocusIndex = clamped
            onLibraryFocusMove?(clamped)
        }
    }

    func setLibraryMenuItemCount(_ count: Int) {
        libraryMenuItemCount = max(1, count)
        libraryMenuIndex = min(libraryMenuIndex, libraryMenuItemCount - 1)
    }

    func focusLibraryIndex(_ index: Int) {
        let next = min(libraryGridCount - 1, max(0, index))
        libraryFocusRegion = .grid
        guard next != libraryFocusIndex else { return }
        libraryFocusIndex = next
        onLibraryFocusMove?(next)
    }

    func focusLibraryMenuIndex(_ index: Int) {
        libraryFocusRegion = .menu
        libraryMenuIndex = min(libraryMenuItemCount - 1, max(0, index))
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func openLibraryCollection(_ id: String) {
        activeLibraryCollectionID = id
        libraryFocusRegion = .grid
        libraryFocusIndex = 0
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func leaveLibraryCollection() {
        guard activeLibraryCollectionID != nil else { return }
        activeLibraryCollectionID = nil
        libraryFocusRegion = .grid
        libraryFocusIndex = 0
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func finishLibrarySearch() {
        guard isLibrarySearchActive else { return }
        isLibrarySearchActive = false
        libraryFocusRegion = .utilities
        libraryUtilityIndex = 0
        onLibrarySearchChanged?(false)
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func changeLibraryTab(by amount: Int) {
        let next = (libraryTab.rawValue + amount + ConsoleLibraryTab.allCases.count) % ConsoleLibraryTab.allCases.count
        guard let tab = ConsoleLibraryTab(rawValue: next) else { return }
        libraryTab = tab
        activeLibraryCollectionID = nil
        libraryFocusRegion = .grid
        libraryFocusIndex = 0
        libraryMenu = nil
        onLibraryTabChanged?(tab)
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func focusLibraryTab(_ tab: ConsoleLibraryTab) {
        guard tab != libraryTab else { libraryFocusRegion = .tabs; return }
        libraryTab = tab
        activeLibraryCollectionID = nil
        libraryFocusRegion = .tabs
        libraryFocusIndex = 0
        libraryMenu = nil
        onLibraryTabChanged?(tab)
        onLibraryFocusMove?(libraryFocusIndex)
    }

    func focusLibraryUtility(_ index: Int) {
        libraryFocusRegion = .utilities
        libraryUtilityIndex = min(1, max(0, index))
        onLibraryFocusMove?(libraryFocusIndex)
    }

    private func handleLibrary(_ action: ConsoleInputAction) {
        switch action {
        case .move(.up): if !isCustomizingLibraryHero { moveLibraryVertically(-1) }
        case .move(.down): if !isCustomizingLibraryHero { moveLibraryVertically(1) }
        case .move(.left): isCustomizingLibraryHero ? onLibraryArtworkStep?(-1) : moveLibraryHorizontally(-1)
        case .move(.right): isCustomizingLibraryHero ? onLibraryArtworkStep?(1) : moveLibraryHorizontally(1)
        case .confirm:
            if isCustomizingLibraryHero { finishLibraryHeroCustomization() }
            else { confirmLibraryFocus() }
        case .back: backFromLibrary()
        case .options:
            guard libraryFocusRegion == .grid, libraryTab != .collections else { onBoundaryBump?(.right); return }
            libraryMenu = .gameOptions
            libraryMenuIndex = 0
            libraryMenuItemCount = 7
            libraryFocusRegion = .menu
            onLibraryFocusMove?(libraryFocusIndex)
        case .tabLeft: changeLibraryTab(by: -1)
        case .tabRight: changeLibraryTab(by: 1)
        case .home: openControlCenter()
        case .search: openGlobalSearch()
        }
    }

    private func confirmLibraryFocus() {
        switch libraryFocusRegion {
        case .tabs:
            break
        case .utilities:
            if libraryUtilityIndex == 0 {
                isLibrarySearchActive = true
                libraryFocusRegion = .searchEntry
                onLibrarySearchChanged?(true)
            } else {
                libraryMenu = .sort
                libraryMenuIndex = librarySort.rawValue
                libraryMenuItemCount = ConsoleLibrarySort.allCases.count
                libraryFocusRegion = .menu
            }
            onLibraryFocusMove?(libraryFocusIndex)
        case .searchEntry:
            finishLibrarySearch()
        case .grid:
            onLibraryConfirm?(libraryFocusIndex)
        case .menu:
            guard let libraryMenu else { return }
            switch libraryMenu {
            case .sort:
                if let sort = ConsoleLibrarySort(rawValue: libraryMenuIndex) { librarySort = sort }
                self.libraryMenu = nil
                libraryFocusRegion = .utilities
                libraryUtilityIndex = 1
            case .gameOptions:
                if libraryMenuIndex == 2 {
                    self.libraryMenu = .collectionPicker
                    libraryMenuIndex = 0
                    libraryMenuItemCount = max(1, libraryMenuItemCount)
                } else {
                    self.libraryMenu = nil
                    libraryFocusRegion = .grid
                    onLibraryMenuAction?(libraryMenu, libraryMenuIndex)
                }
            case .collectionPicker:
                self.libraryMenu = nil
                libraryFocusRegion = .grid
                onLibraryMenuAction?(libraryMenu, libraryMenuIndex)
            }
            onLibraryFocusMove?(libraryFocusIndex)
        }
    }

    private func backFromLibrary() {
        if isCustomizingLibraryHero {
            finishLibraryHeroCustomization()
            return
        }
        if libraryMenu == .collectionPicker {
            libraryMenu = .gameOptions
            libraryMenuIndex = 2
            libraryMenuItemCount = 5
            onLibraryFocusMove?(libraryFocusIndex)
            return
        }
        if libraryMenu != nil {
            libraryMenu = nil
            libraryFocusRegion = .grid
            onLibraryFocusMove?(libraryFocusIndex)
            return
        }
        if isLibrarySearchActive {
            if onLibrarySearchBack?() == true { return }
            isLibrarySearchActive = false
            libraryFocusRegion = .utilities
            libraryUtilityIndex = 0
            onLibrarySearchChanged?(false)
            onLibraryFocusMove?(libraryFocusIndex)
            return
        }
        if activeLibraryCollectionID != nil {
            leaveLibraryCollection()
            return
        }
        closeLibrary()
    }

    func beginLibraryHeroCustomization() { isCustomizingLibraryHero = true }

    func finishLibraryHeroCustomization() {
        guard isCustomizingLibraryHero else { return }
        isCustomizingLibraryHero = false
        onLibraryFocusMove?(libraryFocusIndex)
        onLibraryHeroCustomizationFinished?()
    }

    private func moveLibraryHorizontally(_ amount: Int) {
        if libraryMenu != nil {
            let next = libraryMenuIndex + amount
            guard (0..<libraryMenuItemCount).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            libraryMenuIndex = next
            onLibraryFocusMove?(libraryFocusIndex)
            return
        }
        switch libraryFocusRegion {
        case .tabs:
            changeLibraryTab(by: amount)
        case .utilities:
            let next = libraryUtilityIndex + amount
            guard (0...1).contains(next) else { onBoundaryBump?(amount < 0 ? .left : .right); return }
            libraryUtilityIndex = next
            onLibraryFocusMove?(libraryFocusIndex)
        case .grid:
            let column = libraryFocusIndex % libraryGridColumns
            let nextColumn = column + amount
            let next = libraryFocusIndex + amount
            guard (0..<libraryGridColumns).contains(nextColumn), (0..<libraryGridCount).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            libraryFocusIndex = next
            onLibraryFocusMove?(next)
        case .searchEntry:
            onBoundaryBump?(amount < 0 ? .left : .right)
        case .menu:
            break
        }
    }

    private func moveLibraryVertically(_ amount: Int) {
        if libraryMenu != nil {
            let next = libraryMenuIndex + amount
            guard (0..<libraryMenuItemCount).contains(next) else {
                onBoundaryBump?(amount < 0 ? .up : .down)
                return
            }
            libraryMenuIndex = next
            onLibraryFocusMove?(libraryFocusIndex)
            return
        }
        switch libraryFocusRegion {
        case .tabs:
            if amount > 0 { libraryFocusRegion = .utilities; libraryUtilityIndex = 0 }
            else { onBoundaryBump?(.up) }
        case .utilities:
            if amount > 0 { libraryFocusRegion = .grid; libraryFocusIndex = 0; onLibraryFocusMove?(0) }
            else { libraryFocusRegion = .tabs }
        case .grid:
            if amount < 0 {
                if libraryFocusIndex >= libraryGridColumns {
                    libraryFocusIndex -= libraryGridColumns
                    onLibraryFocusMove?(libraryFocusIndex)
                } else {
                    libraryFocusRegion = .utilities
                    libraryUtilityIndex = 1
                }
            } else {
                let next = libraryFocusIndex + libraryGridColumns
                guard next < libraryGridCount else { onBoundaryBump?(.down); return }
                libraryFocusIndex = next
                onLibraryFocusMove?(next)
            }
        case .searchEntry:
            onBoundaryBump?(amount < 0 ? .up : .down)
        case .menu:
            break
        }
    }

    func openControlCenter() {
        guard !isControlCenterPresented else { return }
        isControlCenterPresented = true
        if activeExternalAppTitle != nil {
            selectedControlCenterItem = .power
            activeControlCard = .power
            controlCardItemIndex = 0
        } else {
            selectedControlCenterItem = .home
            activeControlCard = nil
            controlCardItemIndex = 0
        }
        onControlCenterChanged?(true)
        if activeControlCard != nil { onControlCardChanged?(true) }
    }

    func synchronizeExternalAppTitle(_ title: String?) { activeExternalAppTitle = title }

    func closeControlCenter(returnToHome: Bool = false) {
        guard isControlCenterPresented else { return }
        activeControlCard = nil
        isControlCenterPresented = false
        onControlCenterChanged?(false)
        if returnToHome { focus(.gameRibbon(lastFocusedGameIndex)) }
    }

    func setQuickVolume(_ value: Double) {
        let next = min(1, max(0, value))
        guard next != quickVolume else { return }
        quickVolume = next
        onVolumeChanged?(next)
        onControlCenterFocusMove?()
    }

    func synchronizeQuickVolume(_ value: Double) {
        quickVolume = min(1, max(0, value))
    }

    func synchronizeControllerCount(_ count: Int) {
        connectedControllerCount = max(0, count)
        if isGlobalSearchPresented { setGlobalSearchKeyboardVisible(connectedControllerCount > 0) }
        if activeControlCard == .accessories {
            controlCardItemIndex = min(controlCardItemIndex, max(0, connectedControllerCount - 1))
        }
    }

    func resetLauncher() {
        if isControlCenterPresented { closeControlCenter() }
        dismissMediaModal()
        selectedTab = .games
        showingBelowFold = false
        showingMediaBelowFold = false
        selectedGameIndex = 0
        lastFocusedGameIndex = 0
        selectedMediaIndex = 0
        lastFocusedMediaIndex = 0
        lastMediaBelowFoldIndices = Array(repeating: 0, count: mediaBelowFoldRowCounts.count)
        lastTopBarItem = .games
        lastHeroAction = .play
        lastBelowFoldIndices = Array(repeating: 0, count: belowFoldRowCounts.count)
        dismissOverviewModal()
        activeControlCard = nil
        controlCardItemIndex = 0
        focus(.gameRibbon(0))
    }

    func moveAudioOutput(by amount: Int) {
        let next = (selectedAudioOutputIndex + amount + 3) % 3
        guard next != selectedAudioOutputIndex else { return }
        selectedAudioOutputIndex = next
        onAudioOutputChanged?(next)
        onControlCenterFocusMove?()
    }

    private func handleControlCenter(_ action: ConsoleInputAction) {
        switch action {
        case .move(.left):
            if activeControlCard == .sound {
                if controlCardItemIndex == 0 { setQuickVolume(quickVolume - 0.05) }
                else if controlCardItemIndex == 1 { moveAudioOutput(by: -1) }
                else { onBoundaryBump?(.left) }
            } else if activeControlCard == nil {
                moveControlDock(by: -1)
            } else { onBoundaryBump?(.left) }
        case .move(.right):
            if activeControlCard == .sound {
                if controlCardItemIndex == 0 { setQuickVolume(quickVolume + 0.05) }
                else if controlCardItemIndex == 1 { moveAudioOutput(by: 1) }
                else { onBoundaryBump?(.right) }
            } else if activeControlCard == nil {
                moveControlDock(by: 1)
            } else { onBoundaryBump?(.right) }
        case .move(.up):
            guard activeControlCard != nil else { onBoundaryBump?(.up); return }
            moveControlCard(by: -1)
        case .move(.down):
            guard activeControlCard != nil else { onBoundaryBump?(.down); return }
            moveControlCard(by: 1)
        case .confirm:
            if let activeControlCard {
                if activeControlCard == .power { onPowerAction?(controlCardItemIndex) }
                else { onControlCardConfirm?(activeControlCard, controlCardItemIndex) }
            } else if selectedControlCenterItem == .home {
                closeControlCenter(returnToHome: true)
            } else {
                activeControlCard = switch selectedControlCenterItem {
                case .home: nil
                case .network: .network
                case .sound: .sound
                case .accessories: .accessories
                case .power: .power
                }
                controlCardItemIndex = 0
                onControlCardChanged?(true)
            }
        case .back:
            if activeControlCard != nil {
                activeControlCard = nil
                controlCardItemIndex = 0
                onControlCenterBack?()
            } else {
                closeControlCenter()
            }
        case .home:
            closeControlCenter()
            onControlCenterBack?()
        case .options, .tabLeft, .tabRight, .search:
            break
        }
    }

    private func moveControlDock(by amount: Int) {
        let next = selectedControlCenterItem.rawValue + amount
        guard ConsoleControlCenterItem.allCases.indices.contains(next),
              let item = ConsoleControlCenterItem(rawValue: next) else {
            onBoundaryBump?(amount < 0 ? .left : .right)
            return
        }
        selectedControlCenterItem = item
        onControlCenterFocusMove?()
    }

    private func moveControlCard(by amount: Int) {
        guard let activeControlCard else { return }
        let count: Int
        switch activeControlCard {
        case .network: count = 1
        case .sound: count = 2
        case .accessories: count = max(1, connectedControllerCount)
        case .power: count = activeExternalAppTitle == nil ? 3 : 5
        }
        let next = controlCardItemIndex + amount
        guard (0..<count).contains(next) else {
            onBoundaryBump?(amount < 0 ? .up : .down)
            return
        }
        controlCardItemIndex = next
        onControlCenterFocusMove?()
    }

    private func moveUp() {
        switch focusTarget {
        case .topBar: onBoundaryBump?(.up)
        case .gameRibbon: focus(.topBar(lastTopBarItem))
        case .heroActions: focus(.gameRibbon(lastFocusedGameIndex))
        case .belowFold(let row, _):
            if row == 0 { focus(.heroActions(.play)) }
            else {
                let previousRow = row - 1
                focus(.belowFold(row: previousRow, index: lastBelowFoldIndices[previousRow]))
            }
        case .mediaRibbon: focus(.topBar(.media))
        case .mediaHeroActions: focus(.mediaRibbon(lastFocusedMediaIndex))
        case .mediaBelowFold(let row, _):
            if row == 0 { focus(.mediaHeroActions(.open)) }
            else {
                let previousRow = row - 1
                focus(.mediaBelowFold(row: previousRow, index: lastMediaBelowFoldIndices[previousRow]))
            }
        }
    }

    private func moveDown() {
        switch focusTarget {
        case .topBar:
            if selectedTab == .media { focus(.mediaRibbon(lastFocusedMediaIndex)) }
            else { focus(.gameRibbon(lastFocusedGameIndex)) }
        case .gameRibbon: focus(.heroActions(.play))
        case .heroActions: focus(.belowFold(row: 0, index: lastBelowFoldIndices[0]))
        case .belowFold(let row, _):
            guard row + 1 < belowFoldRowCounts.count else { onBoundaryBump?(.down); return }
            let nextRow = row + 1
            focus(.belowFold(row: nextRow, index: lastBelowFoldIndices[nextRow]))
        case .mediaRibbon: focus(.mediaHeroActions(.open))
        case .mediaHeroActions: focus(.mediaBelowFold(row: 0, index: lastMediaBelowFoldIndices[0]))
        case .mediaBelowFold(let row, _):
            guard row + 1 < mediaBelowFoldRowCounts.count else { onBoundaryBump?(.down); return }
            let nextRow = row + 1
            focus(.mediaBelowFold(row: nextRow, index: lastMediaBelowFoldIndices[nextRow]))
        }
    }

    private func moveHorizontally(_ amount: Int) {
        switch focusTarget {
        case .topBar(let item):
            guard let index = ConsoleTopBarItem.allCases.firstIndex(of: item) else { return }
            let next = index + amount
            guard ConsoleTopBarItem.allCases.indices.contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            focus(.topBar(ConsoleTopBarItem.allCases[next]))
        case .gameRibbon(let index):
            let next = index + amount
            guard (0...(gameCount)).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            focus(.gameRibbon(next))
        case .heroActions(let action):
            if action == .play, amount > 0 { focus(.heroActions(.options)) }
            else if action == .options, amount < 0 { focus(.heroActions(.play)) }
            else { onBoundaryBump?(amount < 0 ? .left : .right) }
        case .belowFold(let row, let index):
            let next = index + amount
            guard (0..<belowFoldRowCounts[row]).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            focus(.belowFold(row: row, index: next))
        case .mediaRibbon(let index):
            let next = index + amount
            guard (0..<mediaCount).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            focus(.mediaRibbon(next))
        case .mediaHeroActions(let action):
            if action == .open, amount > 0 { focus(.mediaHeroActions(.options)) }
            else if action == .options, amount < 0 { focus(.mediaHeroActions(.open)) }
            else { onBoundaryBump?(amount < 0 ? .left : .right) }
        case .mediaBelowFold(let row, let index):
            let next = index + amount
            guard (0..<mediaBelowFoldRowCounts[row]).contains(next) else {
                onBoundaryBump?(amount < 0 ? .left : .right)
                return
            }
            focus(.mediaBelowFold(row: row, index: next))
        }
    }

    private func moveBack() {
        onBack?()
        switch focusTarget {
        case .belowFold: focus(.heroActions(.play))
        case .heroActions: focus(.gameRibbon(lastFocusedGameIndex))
        case .gameRibbon: focus(.topBar(.games))
        case .topBar(let item):
            if item == .media { selectTab(.games) }
            else { onBoundaryBump?(.left) }
        case .mediaBelowFold: focus(.mediaHeroActions(.open))
        case .mediaHeroActions: focus(.mediaRibbon(lastFocusedMediaIndex))
        case .mediaRibbon: focus(.topBar(.media))
        }
    }
}
