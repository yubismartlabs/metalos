import SwiftUI
import GameController

/// A missing or unknown reading is kept distinct from a genuinely empty battery.
enum ControllerBatteryState: String, Equatable, Sendable {
    case unknown, discharging, charging, full
    init(_ state: GCDeviceBattery.State?) {
        switch state {
        case .discharging: self = .discharging
        case .charging: self = .charging
        case .full: self = .full
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .unknown: "State unavailable"
        case .discharging: "On battery"
        case .charging: "Charging"
        case .full: "Fully charged"
        }
    }
}
enum ControllerBatteryReading {
    static func percentage(level: Float?, state: ControllerBatteryState) -> Int? {
        guard let level, level.isFinite, (0...1).contains(level) else { return nil }
        // Apple initializes level to zero while state is unknown; do not report that as 0%.
        guard state != .unknown || level > 0 else { return nil }
        return Int((level * 100).rounded())
    }
    static func symbol(percent: Int?, state: ControllerBatteryState) -> String {
        if state == .charging { return "battery.100percent.bolt" }
        guard let percent else { return "questionmark.circle" }
        switch percent {
        case ...12: return "battery.0percent"
        case ...37: return "battery.25percent"
        case ...62: return "battery.50percent"
        case ...87: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
struct ControllerStatus: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var productCategory: String
    var isAttached: Bool
    var batteryPercent: Int?
    var batteryState: ControllerBatteryState
    var playerNumber: Int?
    var supportsMotion: Bool
    var supportsHaptics: Bool
    var supportsLight: Bool
    var hasOptionsButton: Bool
    var hasHomeButton: Bool
    var lightPreset: Int? = nil
    var batterySymbol: String { ControllerBatteryReading.symbol(percent: batteryPercent, state: batteryState) }
    var batteryText: String { batteryPercent.map { "\($0)%" } ?? "Unavailable" }
    var isLowBattery: Bool { batteryState != .charging && batteryState != .full && (batteryPercent.map { $0 <= 15 } ?? false) }
}
struct ControllerBatteryBadge: View {
    @ObservedObject var controller = ControllerManager.shared
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gamecontroller")
            if let device = controller.devices.first {
                Image(systemName: device.batterySymbol)
                    .foregroundStyle(device.isLowBattery ? Color.orange : studioAccent)
                Text(device.batteryPercent.map { "\($0)%" } ?? "—").monospacedDigit()
                if controller.devices.count > 1 { Text("+\(controller.devices.count - 1)").foregroundStyle(.secondary) }
            } else { Text("No controller").foregroundStyle(.secondary) }
        }.font(.system(size: 11, weight: .medium))
            .accessibilityLabel(controller.devices.first.map { "\($0.name), battery \($0.batteryText), \($0.batteryState.title)" } ?? "No controller connected")
            .help(controller.devices.first.map { "\($0.name) · \($0.batteryText) · \($0.batteryState.title)" } ?? "Connect a controller over Bluetooth or USB")
    }
}
struct ControllerStatusView: View {
    @Environment(\.consolePageClose) private var closePage
    @ObservedObject private var controller = ControllerManager.shared
    @State private var selectedID: String?
    @State private var controlsFocused = false
    @State private var actionIndex = 0
    @State private var showTester = false
    @State private var lightingGuide = false
    @State private var message: String?
    private var device: ControllerStatus? {
        controller.devices.first(where: { $0.id == selectedID }) ?? controller.devices.first
    }
    private var actions: [ControllerControlAction] { ControllerControlAction.available(for: device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("ACCESSORIES").font(.system(size: 9, weight: .semibold)).tracking(3).foregroundStyle(studioAccent)
                    Text("Controllers").font(.system(size: 33, weight: .light))
                }
                Spacer()
                Button { closePage() } label: {
                    Image(systemName: "xmark").padding(10).background(.white.opacity(0.07), in: Circle())
                }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close controllers").keyboardShortcut(.cancelAction)
            }
            if let device {
                HStack(alignment: .top, spacing: 24) {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(controller.devices) { item in
                                Button { select(item.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "gamecontroller.fill")
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                            Text(item.batteryText).font(.system(size: 11)).opacity(0.65)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(device.id == item.id ? studioBackground : .white.opacity(0.8))
                                        .background(device.id == item.id ? studioAccent : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(ConsoleButtonStyle())
                                    .consoleFocus(!controlsFocused && device.id == item.id, cornerRadius: 10, scale: 1.025)
                                    .accessibilityAddTraits(device.id == item.id ? [.isSelected] : [])
                            }
                        }.padding(6)
                    }.frame(width: 205)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                deviceDetails(device)
                                Divider().opacity(0.3)
                                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                                    controlRow(action, index: index, device: device).id(index)
                                }
                                if let message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityLabel(message) }
                            }.padding(8)
                        }.onChange(of: actionIndex) { _, index in
                            withAnimation(ConsoleFeedback.shared.pageAnimation) { proxy.scrollTo(index, anchor: .center) }
                        }
                    }.frame(maxWidth: .infinity)
                }.frame(height: 425)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "gamecontroller").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(studioAccent)
                    Text("No controller connected").font(.title3.weight(.light))
                    Text("Connect a controller using Bluetooth or USB. Battery and supported controls will appear here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 300)
            }
            Divider().opacity(0.3)
            Text(controlsFocused ? "↑ ↓  Choose setting     ← →  Adjust     A  Select     B  Controllers     LB / RB  Switch device" : "↑ ↓  Choose controller     A / →  Settings     B  Close")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(30).frame(width: 800).background(studioBackground).preferredColorScheme(.dark).tint(studioAccent)
            .onAppear { controller.refreshStatus(); reconcileSelection() }
            .onChange(of: controller.devices.map(\.id)) { _, _ in reconcileSelection() }
            .consoleInput(onCommand: navigate)
            .consolePage(isPresented: $showTester) { GamepadTesterView(initialDeviceID: device?.id, lightingGuide: lightingGuide) }
    }
    private func deviceDetails(_ device: ControllerStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(device.productCategory.isEmpty ? device.name : device.productCategory).font(.system(size: 22, weight: .light))
            HStack(spacing: 12) {
                Image(systemName: device.batterySymbol).font(.system(size: 26))
                Text(device.batteryText).font(.system(size: 34, weight: .light)).monospacedDigit()
                Spacer()
            }.foregroundStyle(device.isLowBattery ? .orange : studioAccent)
            if let percent = device.batteryPercent { ProgressView(value: Double(percent), total: 100).tint(studioAccent) }
            Text(device.batteryState.title).font(.caption).foregroundStyle(.secondary)
            if device.batteryPercent == nil { Text("macOS has not supplied a battery reading.").font(.caption).foregroundStyle(.tertiary) }
            Text(device.playerNumber.map { "Player \($0)" } ?? "Player unassigned").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                feature("Light", supported: device.supportsLight)
                feature("Vibration", supported: device.supportsHaptics)
                feature("Motion", supported: device.supportsMotion)
            }
        }
    }
    private func feature(_ title: String, supported: Bool) -> some View {
        Label(title, systemImage: supported ? "checkmark.circle" : "minus.circle")
            .font(.system(size: 10)).foregroundStyle(supported ? studioAccent : .white.opacity(0.35))
    }
    private func controlRow(_ action: ControllerControlAction, index: Int, device: ControllerStatus) -> some View {
        Button { controlsFocused = true; actionIndex = index; perform(action, delta: 1) } label: {
            HStack(spacing: 12) {
                Image(systemName: action.symbol).frame(width: 22).foregroundStyle(studioAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.title).font(.system(size: 13, weight: .medium))
                    Text(action.subtitle)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if action == .light, let index = device.lightPreset {
                    Circle().fill(Color(ControllerManager.lightPresets[index].color)).frame(width: 16, height: 16)
                }
                Text(value(action, device: device)).font(.system(size: 11, weight: .medium)).foregroundStyle(studioAccent)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(controlsFocused && actionIndex == index ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(controlsFocused && actionIndex == index, cornerRadius: 11, scale: 1.02)
            .accessibilityAddTraits(controlsFocused && actionIndex == index ? [.isSelected] : [])
    }
    private func value(_ action: ControllerControlAction, device: ControllerStatus) -> String {
        switch action {
        case .light: device.lightPreset.map { ControllerManager.lightPresets[$0].name } ?? "Custom"
        case .player: device.playerNumber.map { "P\($0)" } ?? "Unassigned"
        case .vibration: "Test"
        case .tester, .lightingHelp: "Open"
        }
    }
    private func reconcileSelection() {
        if !controller.devices.contains(where: { $0.id == selectedID }) { selectedID = controller.devices.first?.id; controlsFocused = false; actionIndex = 0 }
        actionIndex = min(actionIndex, max(actions.count - 1, 0))
    }
    private func select(_ id: String) { selectedID = id; actionIndex = 0; message = nil; controlsFocused = false }
    private func switchDevice(_ delta: Int) {
        guard !controller.devices.isEmpty else { return }
        let current = controller.devices.firstIndex(where: { $0.id == device?.id }) ?? 0
        let next = min(max(current + delta, 0), controller.devices.count - 1)
        let wasFocused = controlsFocused
        select(controller.devices[next].id); controlsFocused = wasFocused
    }
    private func navigate(_ command: String) {
        switch command {
        case "back": if controlsFocused { controlsFocused = false } else { closePage() }
        case "menu", "context": closePage()
        case "previous": switchDevice(-1)
        case "next": switchDevice(1)
        case "up", "down":
            let delta = command == "up" ? -1 : 1
            if controlsFocused { actionIndex = min(max(actionIndex + delta, 0), max(actions.count - 1, 0)) }
            else { switchDevice(delta) }
        case "left", "right":
            if !controlsFocused { controlsFocused = command == "right" && device != nil }
            else if let action = actions[safe: actionIndex], action == .light || action == .player { perform(action, delta: command == "left" ? -1 : 1) }
            else if command == "left" { controlsFocused = false }
        case "confirm":
            if !controlsFocused { controlsFocused = device != nil }
            else if let action = actions[safe: actionIndex] { perform(action, delta: 1) }
        default: break
        }
    }
    private func perform(_ action: ControllerControlAction, delta: Int) {
        guard let device, let gc = controller.controller(id: device.id) else { reconcileSelection(); return }
        message = nil
        switch action {
        case .light:
            let presets = ControllerManager.lightPresets
            let next = ControllerControlAction.cycle(device.lightPreset, delta: delta, count: presets.count)
            if controller.setLightColor(presets[next].color, for: gc) {
                message = "Requested \(presets[next].name). macOS does not confirm the physical light changed. If it stays unchanged, open Lighting help."
            } else { message = "Light control is no longer available." }
        case .player:
            let next = ControllerControlAction.cycle(device.playerNumber.map { $0 - 1 }, delta: delta, count: 4)
            if !controller.setPlayerNumber(next, for: gc) { message = "Player assignment is no longer available." }
        case .vibration:
            do { try controller.playHaptics(for: gc); message = "Vibration pulse sent." }
            catch { message = error.localizedDescription }
        case .tester: lightingGuide = false; showTester = true
        case .lightingHelp: lightingGuide = true; showTester = true
        }
    }
}
enum ControllerControlAction: Hashable {
    case light, player, vibration, tester, lightingHelp
    static func available(for device: ControllerStatus?) -> [Self] {
        guard let device else { return [] }
        return (device.supportsLight ? [.light, .lightingHelp] : [.lightingHelp]) + [.player] + (device.supportsHaptics ? [.vibration] : []) + [.tester]
    }
    static func cycle(_ current: Int?, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard let current else { return delta < 0 ? count - 1 : 0 }
        return ((current + delta) % count + count) % count
    }
    var subtitle: String {
        switch self {
        case .light: "Left / Right sends a color request; physical support varies"
        case .lightingHelp: "GameSir T3 Lite lighting controls and troubleshooting"
        case .player: "Left / Right assigns a player"
        case .tester: "Buttons, triggers, sticks and D-pad"
        case .vibration: "Play a short vibration pulse"
        }
    }
    var title: String {
        switch self { case .light: "Light color request"; case .lightingHelp: "Lighting help"; case .player: "Player number"; case .vibration: "Vibration test"; case .tester: "Gamepad tester" }
    }
    var symbol: String {
        switch self { case .lightingHelp: "questionmark.circle"; case .light: "lightbulb"; case .player: "person"; case .vibration: "waveform"; case .tester: "gamecontroller" }
    }
}
private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension Color {
    init(_ gcColor: GCColor) {
        self.init(red: Double(gcColor.red), green: Double(gcColor.green), blue: Double(gcColor.blue))
    }
}
