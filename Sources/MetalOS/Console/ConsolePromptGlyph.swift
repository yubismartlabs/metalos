import AppKit
import Combine
import GameController
import SwiftUI

enum ConsolePromptControl {
    case confirm, back, details, secondary, previousTab, nextTab, menu, context, guide

    func element(on pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .confirm: pad.buttonA
        case .back: pad.buttonB
        case .details: pad.buttonX
        case .secondary: pad.buttonY
        case .previousTab: pad.leftShoulder
        case .nextTab: pad.rightShoulder
        case .menu: pad.buttonMenu
        case .context: pad.buttonOptions
        case .guide: pad.buttonHome
        }
    }
}

/// The caller supplies the label used when no symbol or controller name is available.
struct ConsolePromptGlyph: View {
    let control: ConsolePromptControl
    let fallbackLabel: String

    @State private var symbol: String?
    @State private var label: String?
    @ObservedObject private var preferences = ConsolePreferences.shared

    private var changes: Publishers.MergeMany<NotificationCenter.Publisher> {
        let center = NotificationCenter.default
        return Publishers.MergeMany([
            .GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent,
            .GCControllerDidConnect, .GCControllerDidDisconnect,
            .GCControllerUserCustomizationsDidChange
        ].map { center.publisher(for: $0) })
    }

    var body: some View {
        Group {
            if let override = preferences.glyphs.label(for: control) {
                Text(override)
            } else if let symbol {
                Image(systemName: symbol)
            } else {
                Text(label ?? fallbackLabel)
            }
        }
        .font(ConsoleDesign.Typography.metadata)
        .accessibilityLabel(Text(preferences.glyphs.label(for: control) ?? label ?? fallbackLabel))
        .onAppear(perform: refresh)
        .onChange(of: control) { _, _ in refresh() }
        .onReceive(changes.receive(on: RunLoop.main)) { _ in refresh() }
    }

    private func refresh() {
        let pad = GCController.current?.extendedGamepad
            ?? GCController.controllers().compactMap(\.extendedGamepad).first
        let element = pad.flatMap { control.element(on: $0) }
        label = element?.localizedName
        symbol = element?.sfSymbolsName.flatMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : name
        }
    }
}
