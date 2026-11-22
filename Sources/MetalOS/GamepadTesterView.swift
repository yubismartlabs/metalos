import SwiftUI
import GameController
import AppKit
import Combine

/// Read the selected device directly, never the last controller that sent a navigation event.
struct GamepadSnapshot {
    var buttons: [String: Bool] = [:]
    var leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0
    var dpadX: Float = 0, dpadY: Float = 0, leftTrigger: Float = 0, rightTrigger: Float = 0
    init(_ pad: GCExtendedGamepad? = nil) {
        guard let pad else { return }
        buttons = ["A": pad.buttonA.isPressed, "B": pad.buttonB.isPressed,
                   "X": pad.buttonX.isPressed, "Y": pad.buttonY.isPressed,
                   "L1": pad.leftShoulder.isPressed, "R1": pad.rightShoulder.isPressed,
                   "Menu": pad.buttonMenu.isPressed, "Options": pad.buttonOptions?.isPressed ?? false,
                   "Home": pad.buttonHome?.isPressed ?? false,
                   "L3": pad.leftThumbstickButton?.isPressed ?? false, "R3": pad.rightThumbstickButton?.isPressed ?? false]
        leftX = pad.leftThumbstick.xAxis.value; leftY = pad.leftThumbstick.yAxis.value
        rightX = pad.rightThumbstick.xAxis.value; rightY = pad.rightThumbstick.yAxis.value
        dpadX = pad.dpad.xAxis.value; dpadY = pad.dpad.yAxis.value
        leftTrigger = pad.leftTrigger.value; rightTrigger = pad.rightTrigger.value
    }
}
struct GamepadTesterView: View {
    @Environment(\.consolePageClose) private var closePage
    @ObservedObject private var controller = ControllerManager.shared
    var initialDeviceID: String? = nil
    var lightingGuide = false
    @State private var selectedID: String?
    @StateObject private var session = GamepadTesterSession()
    private var snapshot: GamepadSnapshot { session.snapshot }
    @State private var testingToken: UUID?
    @State private var backHeldSince: Date?
    @State private var backProgress: Double = 0
    private var device: ControllerStatus? { controller.devices.first { $0.id == selectedID } }
    private var pad: GCExtendedGamepad? { controller.controller(id: selectedID)?.extendedGamepad }
    private var testing: Bool { testingToken != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lightingGuide ? "LIGHTING HELP" : "GAMEPAD TESTER").font(.system(size: 9, weight: .semibold)).tracking(3).foregroundStyle(studioAccent)
                    Text(lightingGuide ? "GameSir T3 Lite" : "Controller Input").font(.system(size: 30, weight: .light))
                }
                Spacer()
                Button { closePage() } label: { Image(systemName: "xmark").padding(10).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close tester").keyboardShortcut(.cancelAction)
            }
            if device == nil {
                VStack(spacing: 18) {
                    Image(systemName: "gamecontroller").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(studioAccent)
                    Text("No controller connected").font(.title3.weight(.light))
                    Text("Connect a controller over Bluetooth or USB to test its inputs.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 300)
            } else {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(controller.devices) { device in
                            Button(device.name) { choose(device.id) }
                        }
                    } label: { Label(device?.name ?? "Controller", systemImage: "gamecontroller") }
                    .disabled(testing)
                    Spacer()
                    Text(testing ? "INPUT · \(session.eventCount) EVENTS" : "PAUSED").font(.system(size: 10, weight: .semibold)).foregroundStyle(studioAccent)
                    Button(testing ? "Pause test" : "Start test") { if testing { stopTesting() } else { startTesting() } }
                        .buttonStyle(ConsoleButtonStyle()).padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        .consoleFocus(!testing, cornerRadius: 9)
                }
                if lightingGuide {
                    lightingInstructions
                } else if pad != nil {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                            group("FACE BUTTONS") { HStack(spacing: 12) { indicator("A"); indicator("B"); indicator("X"); indicator("Y") } }
                            group("SHOULDERS & TRIGGERS") { HStack(spacing: 12) { indicator("L1"); indicator("R1"); indicator("L2", value: snapshot.leftTrigger); indicator("R2", value: snapshot.rightTrigger) } }
                            group("SYSTEM & STICK BUTTONS") {
                                HStack(spacing: 8) { indicator("Menu"); indicator("Options"); indicator("Home"); indicator("L3"); indicator("R3") }
                            }
                            group("D-PAD") {
                                HStack(spacing: 10) {
                                    direction("↑", active: snapshot.dpadY > 0.5); direction("↓", active: snapshot.dpadY < -0.5)
                                    direction("←", active: snapshot.dpadX < -0.5); direction("→", active: snapshot.dpadX > 0.5)
                                }
                            }
                            group("LEFT STICK") { stick(x: snapshot.leftX, y: snapshot.leftY) }
                            group("RIGHT STICK") { stick(x: snapshot.rightX, y: snapshot.rightY) }
                        }.padding(8)
                    }.frame(height: 440)
                } else {
                    Text("This controller does not expose an extended gamepad profile to macOS.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 8) {
                Text(testing ? (lightingGuide ? "Launcher navigation is paused while you adjust the light. Hold B / Circle for 1 second to finish." : "Test any button, including B / Circle and Menu. Hold B / Circle for 1 second to pause.") : "A / Cross  Start test     LB / RB  Choose controller     B / Circle  Close")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if testing { ProgressView(value: backProgress).tint(studioAccent).frame(height: 3) }
            }
        }.padding(28).frame(width: 850).background(studioBackground).preferredColorScheme(.dark).tint(studioAccent)
            .onAppear {
                controller.refreshStatus()
                selectedID = controller.devices.first(where: { $0.id == initialDeviceID })?.id ?? controller.devices.first?.id
                session.select(selectedID, manager: controller)
                startTesting()
            }
            .onDisappear { stopTesting(); session.stop() }
            .onChange(of: controller.devices.map(\.id)) { _, _ in
                if !controller.devices.contains(where: { $0.id == selectedID }) {
                    stopTesting(); selectedID = controller.devices.first?.id; session.select(selectedID, manager: controller)
                }
            }
            .onReceive(session.$sampleTime) { now in
                guard testing else { return }
                if snapshot.buttons["B"] == true {
                    if backHeldSince == nil { backHeldSince = now }
                    backProgress = min(now.timeIntervalSince(backHeldSince ?? now), 1)
                    if backProgress >= 1 { stopTesting() }
                } else { backHeldSince = nil; backProgress = 0 }
            }
            .consoleInput { command in
                // Raw gamepad input is captured by ControllerManager while testing.
                // Keyboard Escape can still close the sheet.
                if command == "back" { closePage() }
                else if !testing {
                    if command == "confirm" { startTesting() }
                    else if ["previous", "next", "left", "right"].contains(command) { changeDevice(command == "previous" || command == "left" ? -1 : 1) }
                }
            }
    }
    private var lightingInstructions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("This guide is for GameSir Tegenaria Lite (T3 Lite). macOS can expose a DualShock profile even when a controller uses its own lighting controls.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            lightingStep("1", title: "Enable color", instruction: "Hold M and press D-pad Up to raise saturation. The default is 0% saturation, which displays white.")
            lightingStep("2", title: "Choose a color", instruction: "Keep M held and rotate the right stick. The stick position selects the color.")
            lightingStep("3", title: "Adjust brightness", instruction: "Hold M and move the left stick Up or Down. Brightness has five levels, including Off.")
            Text("The controller saves these lighting settings across restarts. The launcher cannot read back their physical color.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Link("GameSir lighting instructions", destination: URL(string: "https://gamesir.com/pages/faq-questions-about-tegenaria-lite")!)
                .font(.system(size: 12)).foregroundStyle(studioAccent)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    private func lightingStep(_ number: String, title: String, instruction: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 15, weight: .semibold)).foregroundStyle(studioAccent)
                .frame(width: 30, height: 30).background(.white.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(instruction).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func startTesting() {
        guard testingToken == nil, pad != nil else { return }
        backHeldSince = nil; backProgress = 0
        testingToken = controller.beginTesting()
    }
    private func stopTesting() {
        if let token = testingToken { controller.endTesting(token) }
        testingToken = nil; backHeldSince = nil; backProgress = 0
    }
    private func choose(_ id: String) { stopTesting(); selectedID = id; session.select(id, manager: controller) }
    private func changeDevice(_ delta: Int) {
        guard !controller.devices.isEmpty else { return }
        let index = controller.devices.firstIndex { $0.id == selectedID } ?? 0
        choose(controller.devices[ControllerControlAction.cycle(index, delta: delta, count: controller.devices.count)].id)
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
    private func indicator(_ name: String, value: Float? = nil) -> some View {
        let active = value.map { $0 > 0.05 } ?? (session.recentButtons.contains(name) || snapshot.buttons[name] == true)
        return VStack(spacing: 6) {
            Text(name).font(.system(size: name.count > 3 ? 9 : 13, weight: .semibold))
                .frame(width: 44, height: 44).background(active ? studioAccent : .white.opacity(0.07), in: Circle())
                .foregroundStyle(active ? studioBackground : .white.opacity(0.6))
            if let value { Text("\(Int(value * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
        }.accessibilityLabel("\(name), \(active ? "pressed" : "released")")
    }
    private func direction(_ label: String, active: Bool) -> some View {
        Text(label).font(.system(size: 20)).frame(width: 42, height: 42)
            .background(active ? studioAccent : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(active ? studioBackground : .white.opacity(0.6))
    }
    private func stick(x: Float, y: Float) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.06)).frame(width: 116, height: 116)
                Circle().fill(studioAccent).frame(width: 20, height: 20).offset(x: CGFloat(x) * 46, y: -CGFloat(y) * 46)
            }
            Text(String(format: "X %+.2f   Y %+.2f", x, y)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
