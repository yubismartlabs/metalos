import Combine
import GameController
import Metal
import SwiftUI

struct ConsoleHomeStatus {
    let batteryPercent: Int?
    let batterySymbol: String
    let controllerDescription: String
    let networkSymbol: String
    let networkDescription: String
    let metalAvailable: Bool

    @MainActor static func live(controller: ControllerManager, activeID id: String?, network: NetworkPathSnapshot) -> Self {
        let device = controller.devices.first { $0.id == id }
            ?? controller.devices.first { controller.controller(id: $0.id)?.extendedGamepad != nil }
        return Self(
            batteryPercent: device?.batteryPercent,
            batterySymbol: device?.batterySymbol ?? "gamecontroller",
            controllerDescription: device.map { "\($0.name), battery \($0.batteryText)" } ?? "No controller connected",
            networkSymbol: network.wifiActive ? "wifi" : network.connected ? "network" : "wifi.slash",
            networkDescription: network.headline,
            metalAvailable: metalPresent
        )
    }

    private static let metalPresent = MTLCreateSystemDefaultDevice() != nil
}

struct ConsoleLiveHomeStatus: View {
    @ObservedObject private var controller = ControllerManager.shared
    @StateObject private var network = NetworkPathStatus()
    @State private var activeID: String?

    var body: some View {
        ConsoleHomeStatusView(status: .live(controller: controller, activeID: activeID, network: network.snapshot))
            .onAppear(perform: refreshCurrentDevice)
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidBecomeCurrent)) { _ in
                refreshCurrentDevice()
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidStopBeingCurrent)) { _ in
                refreshCurrentDevice()
            }
    }

    private func refreshCurrentDevice() {
        activeID = GCController.current.map(ControllerManager.deviceID)
    }
}

struct ConsoleHomeStatusView: View {
    let status: ConsoleHomeStatus

    var body: some View {
        HStack(spacing: ConsoleDesign.Space.related) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .fixedSize()
            }
            HStack(spacing: 5) {
                Image(systemName: status.batterySymbol)
                if let battery = status.batteryPercent {
                    Text("\(battery)%")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.controllerDescription)
            .help(status.controllerDescription)
            Image(systemName: status.networkSymbol)
                .accessibilityLabel(status.networkDescription)
                .help(status.networkDescription)
            Label("Metal", systemImage: status.metalAvailable ? "cpu" : "exclamationmark.triangle")
                .accessibilityLabel(status.metalAvailable ? "Metal available" : "Metal unavailable")
                .help(status.metalAvailable ? "Metal available" : "Metal unavailable")
        }
        .font(ConsoleDesign.Typography.metadata)
        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
        .fixedSize()
    }
}

struct ConsoleHomePromptBar: View {
    let confirmTitle: String
    let showsGameOptions: Bool
    let backTitle: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ConsoleDesign.Space.gutter) {
                actionPrompts
                Spacer(minLength: 0)
                navigationPrompts
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: ConsoleDesign.Space.gutter) { actionPrompts }
                HStack(spacing: ConsoleDesign.Space.gutter) { navigationPrompts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(ConsoleDesign.Palette.secondaryText)
        .padding(.top, ConsoleDesign.Space.related)
        .overlay(alignment: .top) { Rectangle().fill(ConsoleDesign.Palette.border).frame(height: 1) }
    }

    private var actionPrompts: some View {
        Group {
            HStack(spacing: 7) {
                glyph(.confirm, fallback: "↵")
                Text(confirmTitle)
            }
            if showsGameOptions {
                HStack(spacing: 7) {
                    glyph(.secondary, fallback: "Y")
                    Text("Game Hub")
                }
            }
        }
    }

    private var navigationPrompts: some View {
        Group {
            HStack(spacing: 7) {
                glyph(.previousTab, fallback: "Q")
                glyph(.nextTab, fallback: "E")
                Text("Switch Tab")
            }
            HStack(spacing: 7) {
                glyph(.back, fallback: "Esc")
                Text(backTitle)
            }
        }
    }

    private func glyph(_ control: ConsolePromptControl, fallback: String) -> some View {
        ConsolePromptGlyph(control: control, fallbackLabel: fallback)
            .foregroundStyle(ConsoleDesign.Palette.text)
            .padding(.horizontal, 6)
            .frame(minWidth: 26, minHeight: 25)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
