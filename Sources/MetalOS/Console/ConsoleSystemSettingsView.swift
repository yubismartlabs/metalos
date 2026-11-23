import AppKit
import Combine
import CoreHaptics
import GameController
import SwiftUI

struct LauncherGamePath: Identifiable, Codable, Equatable {
    var id: String
    var path: String
    var enabled: Bool
}

/// Persistent launcher preferences shared by the console screens.
@MainActor
final class ConsoleSettingsStore: ObservableObject {
    static let shared = ConsoleSettingsStore()
    private let defaults: UserDefaults

    @Published var targetDisplay: String { didSet { save(targetDisplay, "launcher.settings.display") } }
    @Published var safeArea: String { didSet { save(safeArea, "launcher.settings.safeArea") } }
    @Published var livingBackground: Bool { didSet { save(livingBackground, "launcher.settings.livingBackground") } }
    @Published var reducedMotion: Bool { didSet { save(reducedMotion, "launcher.settings.reducedMotion") } }
    @Published var uiSoundEffects: Bool { didSet { save(uiSoundEffects, "launcher.settings.uiSounds"); applySoundSettings() } }
    @Published var uiSoundVolume: Double { didSet { save(uiSoundVolume, "launcher.settings.uiVolume"); applySoundSettings() } }
    @Published var ambientMusic: Bool { didSet { save(ambientMusic, "launcher.settings.ambientMusic"); applySoundSettings() } }
    @Published var ambientVolume: Double { didSet { save(ambientVolume, "launcher.settings.ambientVolume"); applySoundSettings() } }
    @Published var soundTheme: String { didSet { save(soundTheme, "launcher.settings.soundTheme"); applySoundSettings() } }
    @Published var buttonPromptStyle: String { didSet { save(buttonPromptStyle, "launcher.settings.promptStyle"); applyPromptStyle() } }
    @Published var stickDeadzone: Double { didSet { save(stickDeadzone, "launcher.settings.deadzone") } }
    @Published var repeatSpeed: String { didSet { save(repeatSpeed, "launcher.settings.repeatSpeed") } }
    @Published var gamePaths: [LauncherGamePath] { didSet { persistPaths() } }
    @Published var mediaFolders: [LauncherGamePath] { didSet { persistMediaFolders() } }
    @Published var autoScan: Bool { didSet { save(autoScan, "launcher.settings.autoScan") } }
    @Published var focusAccent: String { didSet { save(focusAccent, "launcher.settings.focusAccent"); ConsoleDesign.Palette.focus = accentColor } }
    @Published var glassDepth: String { didSet { save(glassDepth, "launcher.settings.glassDepth") } }
    @Published var clock24Hour: Bool { didSet { save(clock24Hour, "launcher.settings.clock24Hour") } }
    @Published var launchAtLogin: Bool {
        didSet { save(launchAtLogin, "launcher.settings.launchAtLogin"); ConsoleModeManager.shared.setEnabled(launchAtLogin) }
    }
    @Published var emulatorProfiles: [EmulatorProfile] {
        didSet { if let data = try? JSONEncoder().encode(emulatorProfiles) { defaults.set(data, forKey: "launcher.settings.emulatorProfiles") } }
    }
    @Published private(set) var scanProgress: Double?
    @Published private(set) var actionMessage: String?
    private var hapticEngine: CHHapticEngine?
    var scanLibraryAction: (@MainActor () async -> Void)?

    let safeAreaOptions = ["Compact", "Standard PS5", "Overscan Safe"]
    let soundThemeOptions = ["Next-Gen Minimal", "Classic Subtle", "Silent"]
    let promptOptions = ["Auto-Detect", "PlayStation", "Xbox", "Keyboard"]
    let repeatOptions = ["Relaxed", "Standard", "Fast"]
    let accentOptions = ["Pure White", "Ice Blue", "Emerald", "Soft Gold"]
    let glassOptions = ["Light", "Balanced", "Deep"]

    var connectedDisplayOptions: [String] { NSScreen.screens.map(\.localizedName) }

    var accentColor: Color {
        switch focusAccent {
        case "Ice Blue": Color(red: 0.43, green: 0.78, blue: 1)
        case "Emerald": Color(red: 0.38, green: 0.92, blue: 0.66)
        case "Soft Gold": Color(red: 1, green: 0.82, blue: 0.48)
        default: .white
        }
    }

    var glassOpacity: Double {
        switch glassDepth {
        case "Light": 0.62
        case "Deep": 0.96
        default: 0.8
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func number(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) as? Double ?? fallback }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        targetDisplay = string("launcher.settings.display", NSScreen.main?.localizedName ?? "Built-in Display")
        safeArea = string("launcher.settings.safeArea", "Standard PS5")
        livingBackground = flag("launcher.settings.livingBackground", true)
        reducedMotion = flag("launcher.settings.reducedMotion", false)
        uiSoundEffects = flag("launcher.settings.uiSounds", false)
        uiSoundVolume = number("launcher.settings.uiVolume", 0.45)
        ambientMusic = flag("launcher.settings.ambientMusic", false)
        ambientVolume = number("launcher.settings.ambientVolume", 0.35)
        soundTheme = string("launcher.settings.soundTheme", "Next-Gen Minimal")
        buttonPromptStyle = string("launcher.settings.promptStyle", "Auto-Detect")
        stickDeadzone = number("launcher.settings.deadzone", 0.35)
        repeatSpeed = string("launcher.settings.repeatSpeed", "Standard")
        if let data = defaults.data(forKey: "launcher.settings.gamePaths"),
           let paths = try? JSONDecoder().decode([LauncherGamePath].self, from: data) {
            gamePaths = paths
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            gamePaths = [
                .init(id: "applications", path: "/Applications", enabled: true),
                .init(id: "user-applications", path: "\(home)/Applications", enabled: true),
                .init(id: "steam", path: "\(home)/Library/Application Support/Steam/steamapps/common", enabled: false)
            ]
        }
        if let data = defaults.data(forKey: "launcher.settings.mediaFolders"),
           let folders = try? JSONDecoder().decode([LauncherGamePath].self, from: data) {
            mediaFolders = folders
        } else {
            mediaFolders = [.init(id: "movies", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies").path, enabled: true)]
        }
        autoScan = flag("launcher.settings.autoScan", true)
        focusAccent = string("launcher.settings.focusAccent", "Pure White")
        glassDepth = string("launcher.settings.glassDepth", "Balanced")
        clock24Hour = flag("launcher.settings.clock24Hour", false)
        launchAtLogin = flag("launcher.settings.launchAtLogin", ConsoleModeManager.shared.isEnabled)
        if let data = defaults.data(forKey: "launcher.settings.emulatorProfiles"),
           let profiles = try? JSONDecoder().decode([EmulatorProfile].self, from: data) {
            emulatorProfiles = profiles
        } else {
            emulatorProfiles = EmulatorProfile.presets
        }
        ConsoleDesign.Palette.focus = accentColor
        applyPromptStyle()
        applySoundSettings()
    }

    func options(for id: String) -> [String] {
        switch id {
        case "targetDisplay": connectedDisplayOptions.isEmpty ? [targetDisplay] : connectedDisplayOptions
        case "safeArea": safeAreaOptions
        case "soundTheme": soundThemeOptions
        case "promptStyle": promptOptions
        case "repeatSpeed": repeatOptions
        case "focusAccent": accentOptions
        case "glassDepth": glassOptions
        default: []
        }
    }

    func selectedOptionIndex(for id: String) -> Int {
        let value: String
        switch id {
        case "targetDisplay": value = targetDisplay
        case "safeArea": value = safeArea
        case "soundTheme": value = soundTheme
        case "promptStyle": value = buttonPromptStyle
        case "repeatSpeed": value = repeatSpeed
        case "focusAccent": value = focusAccent
        case "glassDepth": value = glassDepth
        default: return 0
        }
        return max(0, options(for: id).firstIndex(of: value) ?? 0)
    }

    func select(_ option: String, for id: String) {
        switch id {
        case "targetDisplay": targetDisplay = option
        case "safeArea": safeArea = option
        case "soundTheme": soundTheme = option
        case "promptStyle": buttonPromptStyle = option
        case "repeatSpeed": repeatSpeed = option
        case "focusAccent": focusAccent = option
        case "glassDepth": glassDepth = option
        default: break
        }
        actionMessage = "\(option) selected"
    }

    func toggle(_ id: String) {
        switch id {
        case "livingBackground": livingBackground.toggle()
        case "reducedMotion": reducedMotion.toggle()
        case "uiSounds": uiSoundEffects.toggle()
        case "ambientMusic": ambientMusic.toggle()
        case "autoScan": autoScan.toggle()
        case "clock24Hour": clock24Hour.toggle()
        default:
            if id.hasPrefix("emulator.") {
                toggleEmulatorProfile(String(id.dropFirst("emulator.".count)))
            } else if id.hasPrefix("path."), let index = gamePaths.firstIndex(where: { $0.id == String(id.dropFirst(5)) }) {
                gamePaths[index].enabled.toggle()
            } else if id.hasPrefix("mediaPath."), let index = mediaFolders.firstIndex(where: { $0.id == String(id.dropFirst(10)) }) {
                mediaFolders[index].enabled.toggle()
            }
        }
        actionMessage = nil
    }

    func adjust(_ id: String, by direction: Int) {
        switch id {
        case "uiVolume": uiSoundVolume = min(1, max(0, uiSoundVolume + Double(direction) * 0.05))
        case "ambientVolume": ambientVolume = min(1, max(0, ambientVolume + Double(direction) * 0.05))
        case "deadzone": stickDeadzone = min(0.65, max(0.1, stickDeadzone + Double(direction) * 0.05))
        default: break
        }
        actionMessage = nil
    }

    func addPath(_ path: String) {
        guard !gamePaths.contains(where: { $0.path == path }) else {
            actionMessage = "That folder is already monitored"
            return
        }
        gamePaths.append(.init(id: UUID().uuidString, path: path, enabled: true))
        actionMessage = "Folder added"
    }

    func removePath(_ id: String) {
        gamePaths.removeAll { $0.id == id }
        actionMessage = "Folder removed"
    }

    func addMediaFolder(_ path: String) {
        guard !mediaFolders.contains(where: { $0.path == path }) else {
            actionMessage = "That media folder is already listed"
            return
        }
        mediaFolders.append(.init(id: UUID().uuidString, path: path, enabled: true))
        actionMessage = "Media folder added"
    }

    func removeMediaFolder(_ id: String) {
        mediaFolders.removeAll { $0.id == id }
        actionMessage = "Media folder removed"
    }

    func scanLibrary() {
        guard scanProgress == nil else { return }
        actionMessage = "Scanning monitored folders…"
        scanProgress = 0.05
        Task { @MainActor in
            await scanLibraryAction?()
            scanProgress = nil
            actionMessage = "Library scan complete"
        }
    }

    func toggleEmulatorProfile(_ id: String) {
        guard let index = emulatorProfiles.firstIndex(where: { $0.id == id }) else { return }
        emulatorProfiles[index].enabled.toggle()
        actionMessage = emulatorProfiles[index].enabled
            ? "Scanning \(emulatorProfiles[index].platformLabel) games on the next library scan."
            : "Stopped scanning \(emulatorProfiles[index].platformLabel) games."
    }

    func testHaptics() {
        if let haptics = GCController.controllers().first?.haptics,
           haptics.supportedLocalities.contains(.default),
           let engine = haptics.createEngine(withLocality: .default) {
            do {
                let event = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)],
                    relativeTime: 0
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                try engine.start()
                try engine.makePlayer(with: pattern).start(atTime: 0)
                hapticEngine = engine
                actionMessage = "Controller haptic test sent"
            } catch {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                actionMessage = "System haptic feedback sent"
            }
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            actionMessage = "System haptic feedback sent"
        }
    }

    private func applySoundSettings() {
        UISoundManager.shared.soundThemeName = soundTheme
        UISoundManager.soundEffectsEnabled = uiSoundEffects && soundTheme != "Silent"
        UISoundManager.soundEffectsVolume = Float(uiSoundVolume)
        UISoundManager.ambientMusicEnabled = ambientMusic
        UISoundManager.ambientMusicVolume = Float(ambientVolume)
    }

    private func applyPromptStyle() {
        ConsolePreferences.shared.glyphs = switch buttonPromptStyle {
        case "PlayStation": .playStation
        case "Xbox": .xbox
        case "Keyboard": .keyboard
        default: .auto
        }
    }

    private func persistPaths() {
        guard let data = try? JSONEncoder().encode(gamePaths) else { return }
        defaults.set(data, forKey: "launcher.settings.gamePaths")
    }

    private func persistMediaFolders() {
        guard let data = try? JSONEncoder().encode(mediaFolders) else { return }
        defaults.set(data, forKey: "launcher.settings.mediaFolders")
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}

private struct ConsoleSettingControl: Identifiable {
    enum Kind {
        case toggle(Bool)
        case stepper(Double, ClosedRange<Double>, String)
        case selector(String, [String])
        case action(String)
        case information(String)
    }
    var id: String
    var title: String
    var subtitle: String
    var kind: Kind
}

struct ConsoleSystemSettingsView: View {
    @ObservedObject var focus: FocusCoordinator
    @ObservedObject var input: ConsoleInputManager
    @ObservedObject private var settings = ConsoleSettingsStore.shared
    @ObservedObject private var consoleMode = ConsoleModeManager.shared

    var onSound: (() -> Void)?
    var onDisplaySelected: ((String) -> Void)?

    private var controls: [ConsoleSettingControl] {
        switch focus.settingsCategory {
        case .display:
            var rows = [
                selector("targetDisplay", "Target Display", "Choose the display used by the launcher.", settings.targetDisplay),
                selector("safeArea", "Safe-Area Padding", "Keep controls comfortably inside the screen edge.", settings.safeArea),
                toggle("livingBackground", "Living Background", "Artwork drift and ambient light motes.", settings.livingBackground),
                toggle("reducedMotion", "Reduced Motion", "Use shorter, calmer transitions.", settings.reducedMotion),
                toggle("launchAtLogin", "Launch at Login (Console Mode)", "Start MetalOS automatically when you sign in.", settings.launchAtLogin)
            ]
            if consoleMode.status == .requiresApproval {
                rows.append(action("openLoginItems", "Approve in Login Items", "macOS needs approval before Console Mode can start at login.", "Open"))
            }
            return rows
        case .audio:
            return [
                toggle("uiSounds", "UI Sound Effects", "Soft audio cues for movement and actions.", settings.uiSoundEffects),
                stepper("uiVolume", "UI Sound Volume", "Sound effects level.", settings.uiSoundVolume, "\(Int(settings.uiSoundVolume * 100))%"),
                toggle("ambientMusic", "Ambient Game Music", "Allow per-game background audio.", settings.ambientMusic),
                stepper("ambientVolume", "Ambient Volume", "Background audio level.", settings.ambientVolume, "\(Int(settings.ambientVolume * 100))%"),
                selector("soundTheme", "Sound Theme", "Choose the console sound character.", settings.soundTheme)
            ]
        case .controllers:
            var rows = [ConsoleSettingControl(id: "connected", title: "Connected Controllers", subtitle: input.connectedControllers.isEmpty ? "No controllers connected" : "\(input.connectedControllers.count) controller\(input.connectedControllers.count == 1 ? "" : "s") ready", kind: .information("\(input.connectedControllers.count) connected"))]
            for controller in input.connectedControllers {
                let battery = controller.batteryLevel.map { "\(Int($0 * 100))%\(controller.isCharging ? " · Charging" : "")" } ?? "Battery unavailable"
                rows.append(.init(id: "controller.\(controller.id)", title: controller.productName, subtitle: "Connected accessory", kind: .information(battery)))
            }
            rows += [
                selector("promptStyle", "Button Prompt Style", "Choose the glyphs shown for controls.", settings.buttonPromptStyle),
                stepper("deadzone", "Stick Deadzone", "Reduce unwanted analog stick drift.", settings.stickDeadzone, String(format: "%.2f", settings.stickDeadzone)),
                selector("repeatSpeed", "Hold-to-Repeat", "Set how quickly held directions repeat.", settings.repeatSpeed),
                action("testHaptics", "Test Haptics", "Send a short tactile system feedback pulse.", "Test")
            ]
            return rows
        case .gamePaths:
            var rows = settings.gamePaths.map { path in
                ConsoleSettingControl(id: "path.\(path.id)", title: URL(fileURLWithPath: path.path).lastPathComponent.isEmpty ? path.path : URL(fileURLWithPath: path.path).lastPathComponent,
                                      subtitle: path.path, kind: .toggle(path.enabled))
            }
            rows += settings.gamePaths.map { path in
                action("remove.\(path.id)", "Remove \(URL(fileURLWithPath: path.path).lastPathComponent)", "Stop monitoring this folder.", "Remove")
            }
            rows.append(action("addPath", "Add Folder", "Choose another folder to monitor.", "Add"))
            rows.append(toggle("autoScan", "Auto-Scan on Launch", "Refresh your game collection as the launcher opens.", settings.autoScan))
            rows.append(.init(id: "emulatorProfilesHeader", title: "Emulator Profiles", subtitle: "Scan enabled ROM folders into your game library.", kind: .information("\(settings.emulatorProfiles.filter(\.enabled).count) active")))
            rows += settings.emulatorProfiles.map { profile in
                ConsoleSettingControl(id: "emulator.\(profile.id)", title: "\(profile.platformLabel) · \(profile.name)",
                    subtitle: "\(profile.romDirectoryPath) · \(profile.fileExtensions.map { ".\($0)" }.joined(separator: ", "))",
                    kind: .toggle(profile.enabled))
            }
            rows.append(action("scan", "Scan Library Now", "Search all enabled monitored folders.", "Scan"))
            rows.append(.init(id: "mediaFoldersHeader", title: "Media Folders", subtitle: "Folders scanned for local videos and movies.", kind: .information("\(settings.mediaFolders.filter(\.enabled).count) active")))
            rows += settings.mediaFolders.map { folder in
                ConsoleSettingControl(id: "mediaPath.\(folder.id)", title: URL(fileURLWithPath: folder.path).lastPathComponent,
                                      subtitle: folder.path, kind: .toggle(folder.enabled))
            }
            rows += settings.mediaFolders.map { folder in
                action("removeMedia.\(folder.id)", "Remove \(URL(fileURLWithPath: folder.path).lastPathComponent)", "Stop scanning this media folder.", "Remove")
            }
            rows.append(action("addMediaFolder", "Add Media Folder", "Choose a folder for local movies and videos.", "Add"))
            return rows
        case .theme:
            return [
                selector("focusAccent", "Focus Ring Accent", "Set the color used for selection lighting.", settings.focusAccent),
                selector("glassDepth", "Glass & Vignette Depth", "Tune the frosted surfaces and background dimming.", settings.glassDepth),
                toggle("clock24Hour", "24-Hour Clock", "Switch the top status clock to 24-hour time.", settings.clock24Hour)
            ]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = horizontalInset(for: geometry.size.width)
            ZStack {
                settingsCanvas
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 34)
                    HStack(alignment: .top, spacing: 32) {
                        categoryRail
                            .frame(width: geometry.size.width * 0.31)
                        Rectangle().fill(.white.opacity(0.17)).frame(width: 1).padding(.vertical, 8)
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    footer
                }
                .padding(.horizontal, inset)
                .padding(.top, max(36, geometry.size.height * 0.055))
                .padding(.bottom, max(28, geometry.size.height * 0.04))

                if focus.settingsSelectorOpen { selectorOverlay }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .foregroundStyle(.white)
            .animation(settings.reducedMotion ? .easeOut(duration: 0.12) : ConsoleMotion.zoneSpring, value: focus.settingsCategory)
            .animation(settings.reducedMotion ? .easeOut(duration: 0.12) : ConsoleMotion.focusSpring, value: focus.settingsItemIndex)
            .animation(settings.reducedMotion ? .easeOut(duration: 0.12) : ConsoleMotion.zoneSpring, value: focus.settingsSelectorOpen)
            .onAppear {
                configureFocusCallbacks()
                synchronizeFocusModel()
            }
            .onChange(of: focus.settingsCategory) { _, _ in synchronizeFocusModel() }
            .onChange(of: controls.map(\.id)) { _, _ in synchronizeFocusModel() }
        }
        .ignoresSafeArea()
    }

    private var settingsCanvas: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.065)
            RadialGradient(colors: [settings.accentColor.opacity(0.12), .clear], center: .init(x: 0.78, y: 0.25), startRadius: 20, endRadius: 850)
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.34 + settings.glassOpacity * 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(settings.accentColor.opacity(0.035)).frame(width: 520).blur(radius: 100).offset(x: 300, y: -230)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Settings").font(.system(size: 43, weight: .medium, design: .rounded)).tracking(-1.2)
                Text(focus.settingsCategory.subtitle).font(.system(size: 17, weight: .regular)).foregroundStyle(.white.opacity(0.62))
                    .contentTransition(.opacity)
            }
            Spacer()
            Text("SYSTEM SETTINGS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2.2)
                .foregroundStyle(.white.opacity(0.46))
        }
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(ConsoleSettingsCategory.allCases, id: \.self) { category in
                let selected = category == focus.settingsCategory
                let focused = selected && focus.settingsZone == .categoryRail
                Button {
                    if category != focus.settingsCategory { UISoundManager.playFocusMove() }
                    focus.chooseSettingsCategory(category)
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .frame(width: 26)
                        Text(category.title).font(.system(size: 21, weight: selected ? .semibold : .medium))
                        Spacer()
                        if selected { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.56)) }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.68))
                    .padding(.horizontal, 17)
                    .frame(height: 65)
                    .background(selected ? .white.opacity(focus.settingsZone == .categoryRail ? 0.13 : 0.075) : .clear, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(focused ? settings.accentColor.opacity(0.94) : .white.opacity(selected ? 0.14 : 0), lineWidth: focused ? 2 : 1))
                    .shadow(color: focused ? settings.accentColor.opacity(0.22) : .clear, radius: 18)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
            if focus.settingsZone == .categoryRail {
                Text("\(focus.settingsCategory.rawValue + 1)  /  5")
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.42)).padding(.leading, 18)
            }
        }
        .padding(.top, 4)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(focus.settingsCategory.title).font(.system(size: 28, weight: .semibold))
                Spacer()
                Text("\(controls.count) OPTIONS").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundStyle(.white.opacity(0.42))
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(Array(controls.enumerated()), id: \.element.id) { index, item in
                            settingRow(item, index: index)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focus.settingsItemIndex) { _, index in
                    withAnimation(settings.reducedMotion ? nil : ConsoleMotion.ribbonSpring) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            if let message = settings.actionMessage {
                HStack(spacing: 9) {
                    if settings.scanProgress != nil { ProgressView().controlSize(.small).tint(settings.accentColor) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(settings.accentColor) }
                    Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    if let progress = settings.scanProgress { Text("\(Int(progress * 100))%").font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.55)) }
                }
                .padding(.horizontal, 7).transition(.opacity)
            }
        }
    }

    @ViewBuilder private func settingRow(_ item: ConsoleSettingControl, index: Int) -> some View {
        let selected = focus.settingsZone == .detailPane && focus.settingsItemIndex == index
        Button {
            if focus.settingsZone != .detailPane { UISoundManager.playFocusMove() }
            focus.enterSettingsDetail(at: index)
            activate(item, index: index)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 18, weight: selected ? .semibold : .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.91))
                    Text(item.subtitle).font(.system(size: 13, weight: .regular)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 18)
                controlValue(item.kind, selected: selected)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: item.id.hasPrefix("path.") ? 72 : 76)
                    .background(selected ? .white.opacity(0.12 * settings.glassOpacity) : .white.opacity(0.035 * settings.glassOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? settings.accentColor.opacity(0.92) : .white.opacity(0.075), lineWidth: selected ? 2 : 1))
            .shadow(color: selected ? settings.accentColor.opacity(0.18) : .clear, radius: 17)
            .scaleEffect(selected ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(item.title), \(accessibilityValue(item.kind))")
    }

    @ViewBuilder private func controlValue(_ kind: ConsoleSettingControl.Kind, selected: Bool) -> some View {
        switch kind {
        case .toggle(let enabled):
            HStack(spacing: 8) {
                Text(enabled ? "On" : "Off").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.56))
                Capsule().fill(enabled ? settings.accentColor : .white.opacity(0.18)).frame(width: 46, height: 26)
                    .overlay(alignment: enabled ? .trailing : .leading) { Circle().fill(enabled ? Color.black.opacity(0.82) : Color.white.opacity(0.92)).frame(width: 20, height: 20).padding(3) }
            }
        case .stepper(let value, let range, let label):
            VStack(alignment: .trailing, spacing: 9) {
                Text(label).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.86))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(settings.accentColor.opacity(selected ? 0.95 : 0.72)).frame(width: max(7, geo.size.width * CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))))
                    }
                }
                .frame(width: 122, height: 5)
            }
        case .selector(let value, _):
            HStack(spacing: 10) { Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.82)); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.48)) }
        case .action(let label):
            Text(label.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.7).foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 17).frame(height: 38).background(selected ? settings.accentColor : .white.opacity(0.13), in: Capsule())
        case .information(let value):
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.59))
        }
    }

    private var selectorOverlay: some View {
        let item = controls.indices.contains(focus.settingsItemIndex) ? controls[focus.settingsItemIndex] : nil
        let choices: [String] = { if case .selector(_, let options) = item?.kind { return options }; return [] }()
        return ZStack {
            Color.black.opacity(0.26).ignoresSafeArea()
                .onTapGesture { UISoundManager.playBack(); focus.closeSettingsSelector() }
            VStack(alignment: .leading, spacing: 5) {
                Text(item?.title ?? "Select an option").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.62)).padding(.horizontal, 13).padding(.bottom, 5)
                ForEach(Array(choices.enumerated()), id: \.offset) { index, option in
                    let highlighted = index == focus.settingsSelectorIndex
                    HStack {
                        if option == currentSelectorValue(for: item?.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(settings.accentColor) }
                        else { Image(systemName: "circle").foregroundStyle(.white.opacity(0.35)) }
                        Text(option).font(.system(size: 16, weight: highlighted ? .semibold : .medium))
                        Spacer()
                        if highlighted { Image(systemName: "return").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.48)) }
                    }
                    .foregroundStyle(.white.opacity(highlighted ? 1 : 0.78))
                    .padding(.horizontal, 13).frame(height: 43)
                    .background(highlighted ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(highlighted ? settings.accentColor.opacity(0.75) : .clear, lineWidth: 1.5))
                }
                Text("↑  ↓   Navigate       ↵   Select       Esc   Back").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.42)).padding(.horizontal, 13).padding(.top, 6)
            }
            .padding(12).frame(width: 370, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 38, y: 18)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Text("↑ ↓   Navigate").foregroundStyle(.white.opacity(0.52))
            Text("→   View options").foregroundStyle(.white.opacity(0.52))
            Text("↵   Select").foregroundStyle(.white.opacity(0.52))
            Spacer()
            Text(focus.settingsSelectorOpen ? "ESC   Close selector" : "ESC   Back").foregroundStyle(.white.opacity(0.52))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.13)).frame(height: 1) }
    }

    private func synchronizeFocusModel() {
        let current = controls
        focus.synchronizeSettings(items: current.map { interaction($0.kind) }, selectorOptions: current.indices.contains(focus.settingsItemIndex) ? selectorOptions(current[focus.settingsItemIndex].kind) : [])
    }

    private func configureFocusCallbacks() {
        focus.onSettingsConfirm = { index in
            guard controls.indices.contains(index) else { return }
            activate(controls[index], index: index)
        }
        focus.onSettingsAdjust = { index, direction in
            guard controls.indices.contains(index) else { return }
            adjust(controls[index].id, direction: direction)
        }
        focus.onSettingsSelect = { itemIndex, optionIndex in
            guard controls.indices.contains(itemIndex) else { return }
            let item = controls[itemIndex]
            let choices = settings.options(for: item.id)
            guard choices.indices.contains(optionIndex) else { return }
            settings.select(choices[optionIndex], for: item.id)
            if item.id == "targetDisplay" { onDisplaySelected?(choices[optionIndex]) }
            UISoundManager.playConfirm()
            synchronizeFocusModel()
        }
    }

    private func interaction(_ kind: ConsoleSettingControl.Kind) -> ConsoleSettingInteraction {
        switch kind {
        case .toggle: .toggle
        case .stepper: .stepper
        case .selector: .selector
        case .action: .action
        case .information: .information
        }
    }

    private func selectorOptions(_ kind: ConsoleSettingControl.Kind) -> [String] {
        if case .selector(_, let options) = kind { return options }
        return []
    }

    private func activate(_ item: ConsoleSettingControl, index: Int) {
        switch item.kind {
        case .toggle: settings.toggle(item.id); UISoundManager.playConfirm()
        case .selector(_, let options):
            guard !options.isEmpty else { return }
            focus.openSettingsSelector(selectedIndex: settings.selectedOptionIndex(for: item.id), optionCount: options.count)
            UISoundManager.playConfirm()
        case .stepper: break
        case .action: performAction(item.id)
        case .information: break
        }
        synchronizeFocusModel()
    }

    private func adjust(_ id: String, direction: Int) {
        settings.adjust(id, by: direction)
        UISoundManager.playSliderTick()
        if id == "uiVolume" { onSound?() }
    }

    private func performAction(_ id: String) {
        UISoundManager.playConfirm()
        switch id {
        case "addPath":
            let panel = NSOpenPanel()
            panel.title = "Add a Game Folder"
            panel.message = "Choose a folder for MetalOS to monitor."
            panel.prompt = "Add Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { settings.addPath(url.path) }
        case "addMediaFolder":
            let panel = NSOpenPanel()
            panel.title = "Add a Media Folder"
            panel.message = "Choose a folder containing movies or videos."
            panel.prompt = "Add Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { settings.addMediaFolder(url.path) }
        case "scan": settings.scanLibrary()
        case "testHaptics": settings.testHaptics()
        case "openLoginItems": consoleMode.openLoginItems()
        default:
            if id.hasPrefix("remove.") { settings.removePath(String(id.dropFirst(7))) }
            else if id.hasPrefix("removeMedia.") { settings.removeMediaFolder(String(id.dropFirst(12))) }
        }
    }

    private func currentSelectorValue(for id: String?) -> String? {
        guard let id else { return nil }
        return switch id {
        case "targetDisplay": settings.targetDisplay
        case "safeArea": settings.safeArea
        case "soundTheme": settings.soundTheme
        case "promptStyle": settings.buttonPromptStyle
        case "repeatSpeed": settings.repeatSpeed
        case "focusAccent": settings.focusAccent
        case "glassDepth": settings.glassDepth
        default: nil
        }
    }

    private func accessibilityValue(_ kind: ConsoleSettingControl.Kind) -> String {
        switch kind {
        case .toggle(let value): value ? "On" : "Off"
        case .stepper(_, _, let label), .action(let label), .information(let label): label
        case .selector(let value, _): value
        }
    }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        switch settings.safeArea {
        case "Compact": max(34, width * 0.035)
        case "Overscan Safe": max(76, width * 0.075)
        default: max(52, width * 0.052)
        }
    }

    private func selector(_ id: String, _ title: String, _ subtitle: String, _ value: String) -> ConsoleSettingControl {
        .init(id: id, title: title, subtitle: subtitle, kind: .selector(value, settings.options(for: id)))
    }
    private func toggle(_ id: String, _ title: String, _ subtitle: String, _ value: Bool) -> ConsoleSettingControl {
        .init(id: id, title: title, subtitle: subtitle, kind: .toggle(value))
    }
    private func stepper(_ id: String, _ title: String, _ subtitle: String, _ value: Double, _ label: String) -> ConsoleSettingControl {
        let range: ClosedRange<Double> = id == "deadzone" ? 0.1...0.65 : 0.0...1.0
        return ConsoleSettingControl(id: id, title: title, subtitle: subtitle, kind: .stepper(value, range, label))
    }
    private func action(_ id: String, _ title: String, _ subtitle: String, _ label: String) -> ConsoleSettingControl {
        .init(id: id, title: title, subtitle: subtitle, kind: .action(label))
    }
}
