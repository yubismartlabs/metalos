import AppKit
import CoreAudio
import SwiftUI

/// A full-canvas console layer; it never creates a native popover or settings window.
struct ConsoleControlCenterView: View {
    @ObservedObject var focus: FocusCoordinator
    let network: NetworkPathSnapshot
    let controllers: [ConsoleControllerStatus]
    let activeAppTitle: String?
    let onPowerAction: (Int) -> Void

    private let outputNames = ["Mac Speakers", "Headphones", "HDMI / AirPlay"]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.24))
                    .overlay(Color.black.opacity(0.30))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }

                VStack(spacing: 20) {
                    if let card = focus.activeControlCard {
                        quickCard(card)
                            .frame(width: 372)
                            .offset(x: cardOffset(for: focus.selectedControlCenterItem, width: size.width))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    dock
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial.opacity(0.62), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.19), lineWidth: 1))
                        .shadow(color: .black.opacity(0.36), radius: 30, y: 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(.bottom, max(40, size.height * 0.065))
                .frame(maxWidth: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear {
                if let systemVolume = SystemVolumeController.current() {
                    focus.synchronizeQuickVolume(systemVolume)
                }
            }
        }
        .ignoresSafeArea()
        .animation(ConsoleMotion.zoneSpring, value: focus.activeControlCard)
        .animation(ConsoleMotion.focusSpring, value: focus.selectedControlCenterItem)
    }

    private var dock: some View {
        HStack(spacing: 18) {
            ForEach(ConsoleControlCenterItem.allCases, id: \.rawValue) { item in
                let isFocused = item == focus.selectedControlCenterItem
                Button {
                    if item != focus.selectedControlCenterItem {
                        focus.handle(.move(item.rawValue < focus.selectedControlCenterItem.rawValue ? .left : .right))
                    } else {
                        focus.handle(.confirm)
                    }
                } label: {
                    VStack(spacing: 9) {
                        Text(item.title)
                            .font(.system(size: 13, weight: isFocused ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(isFocused ? 1 : 0))
                            .frame(height: 18)
                        ZStack(alignment: .bottomTrailing) {
                            Circle()
                                .fill(.ultraThinMaterial.opacity(isFocused ? 0.92 : 0.58))
                                .overlay(Circle().fill(.white.opacity(isFocused ? 0.13 : 0.06)))
                                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0.3 : 0.14), lineWidth: 1))
                                .overlay {
                                    Image(systemName: item == .network && !network.connected ? "wifi.slash" : item.symbol)
                                        .font(.system(size: 25, weight: .medium))
                                        .foregroundStyle(.white.opacity(isFocused ? 1 : 0.82))
                                }
                                .frame(width: 72, height: 72)
                            statusBadge(for: item)
                        }
                        .overlay { ConsoleSignatureFocusRing(shape: Circle(), isFocused: isFocused).padding(-3) }
                        .scaleEffect(isFocused ? 1.08 : 1)
                        .shadow(color: isFocused ? .white.opacity(0.22) : .clear, radius: 18)
                    }
                    .frame(width: 86)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isFocused ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for item: ConsoleControlCenterItem) -> some View {
        switch item {
        case .network:
            Circle().fill(network.connected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 2))
                .offset(x: 1, y: 1)
        case .accessories:
            if controllers.isEmpty {
                Circle().fill(.white.opacity(0.48)).frame(width: 10, height: 10).offset(x: 1, y: 1)
            } else if let level = controllers.first?.batteryLevel {
                Text("\(Int(level * 100))")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 23, height: 17)
                    .background(.white, in: Capsule())
                    .overlay(alignment: .trailing) { Rectangle().fill(.white).frame(width: 2, height: 6).offset(x: 2) }
                    .offset(x: 1, y: 1)
            }
        case .home, .sound, .power:
            EmptyView()
        }
    }

    @ViewBuilder
    private func quickCard(_ card: ConsoleControlCard) -> some View {
        switch card {
        case .network:
            cardShell(title: "Network", subtitle: "Connection status") {
                cardRow(index: 0, focused: focus.controlCardItemIndex == 0, symbol: network.connected ? "wifi" : "wifi.slash",
                        title: network.headline, detail: network.detail, trailing: network.connected ? "ONLINE" : "OFFLINE") { }
            }
        case .sound:
            cardShell(title: "Sound", subtitle: "Quick audio controls") {
                volumeRow
                cardRow(index: 1, focused: focus.controlCardItemIndex == 1, symbol: "hifispeaker.fill",
                        title: "Audio output", detail: outputNames[focus.selectedAudioOutputIndex], trailing: "CHANGE") {
                    focus.moveAudioOutput(by: 1)
                }
                Text("Output routing can be connected to CoreAudio later.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.53))
                    .padding(.leading, 4)
            }
        case .accessories:
            cardShell(title: "Accessories", subtitle: "Connected controllers") {
                if controllers.isEmpty {
                    cardRow(index: 0, focused: true, symbol: "gamecontroller", title: "No controller connected",
                            detail: "Pair or connect a controller to get started.", trailing: "") { }
                } else {
                    ForEach(Array(controllers.enumerated()), id: \.element.id) { index, controller in
                        controllerRow(controller, index: index)
                    }
                }
            }
        case .power:
            cardShell(title: activeAppTitle == nil ? "Power" : "Active Game", subtitle: activeAppTitle ?? "Console options") {
                if let activeAppTitle {
                    cardRow(index: 0, focused: focus.controlCardItemIndex == 0, symbol: "play.fill",
                            title: "Resume Active Game", detail: "Return to \(activeAppTitle).", trailing: "RESUME") { onPowerAction(0) }
                    cardRow(index: 1, focused: focus.controlCardItemIndex == 1, symbol: "xmark.circle.fill",
                            title: "Close Active Game", detail: "Ask \(activeAppTitle) to quit.", trailing: "CLOSE") { onPowerAction(1) }
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 2)
                    cardRow(index: 2, focused: focus.controlCardItemIndex == 2, symbol: "rectangle.portrait.and.arrow.right",
                            title: "Return to macOS Desktop", detail: "Quit MetalOS and return to your desktop.", trailing: "") { onPowerAction(2) }
                    cardRow(index: 3, focused: focus.controlCardItemIndex == 3, symbol: "moon.zzz.fill",
                            title: "Put Mac to Sleep", detail: "Use the system power policy to sleep.", trailing: "") { onPowerAction(3) }
                    cardRow(index: 4, focused: focus.controlCardItemIndex == 4, symbol: "arrow.counterclockwise",
                            title: "Restart Launcher", detail: "Reset the console home screen.", trailing: "") { onPowerAction(4) }
                } else {
                    cardRow(index: 0, focused: focus.controlCardItemIndex == 0, symbol: "rectangle.portrait.and.arrow.right",
                            title: "Return to macOS Desktop", detail: "Quit MetalOS and return to your desktop.", trailing: "") { onPowerAction(0) }
                    cardRow(index: 1, focused: focus.controlCardItemIndex == 1, symbol: "moon.zzz.fill",
                            title: "Put Mac to Sleep", detail: "Use the system power policy to sleep.", trailing: "") { onPowerAction(1) }
                    cardRow(index: 2, focused: focus.controlCardItemIndex == 2, symbol: "arrow.counterclockwise",
                            title: "Restart Launcher", detail: "Reset the console home screen.", trailing: "") { onPowerAction(2) }
                }
            }
        }
    }

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("System volume", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int(focus.quickVolume * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 4) {
                ForEach(0..<20, id: \.self) { segment in
                    Capsule()
                        .fill(Double(segment) < focus.quickVolume * 20 ? .white : .white.opacity(0.16))
                        .frame(height: 8)
                }
            }
            Text("Use left and right to adjust")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: focus.controlCardItemIndex == 0).padding(-2) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System volume \(Int(focus.quickVolume * 100)) percent")
    }

    private func controllerRow(_ controller: ConsoleControllerStatus, index: Int) -> some View {
        let batteryText = controller.batteryLevel.map { "\(Int($0 * 100))%" } ?? "Battery unavailable"
        return cardRow(index: index, focused: focus.controlCardItemIndex == index,
                       symbol: controller.isCharging ? "battery.100percent.bolt" : "gamecontroller.fill",
                       title: controller.productName,
                       detail: controller.isCharging ? "\(batteryText) · Charging" : batteryText,
                       trailing: controller.isCharging ? "CHARGING" : "") { }
    }

    private func cardShell<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            content()
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.19), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private func cardRow(index: Int, focused: Bool, symbol: String, title: String, detail: String,
                         trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                }
                Spacer(minLength: 6)
                if !trailing.isEmpty {
                    Text(trailing).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(.white.opacity(0.64))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 14, style: .continuous), isFocused: focused).padding(-2) }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(title), \(detail)")
    }

    private func cardOffset(for item: ConsoleControlCenterItem, width: CGFloat) -> CGFloat {
        let dockStep: CGFloat = 104
        let desired = CGFloat(item.rawValue - 2) * dockStep
        let maximum = max(0, (width - 400) / 2)
        return min(maximum, max(-maximum, desired))
    }
}

enum SystemVolumeController {
    static func current() -> Double? {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return nil }
        var value: Float = 0
        var address = volumeAddress
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func set(_ value: Double) {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var scalar = Float(min(1, max(0, value)))
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return device
    }
}
