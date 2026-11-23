import SwiftUI

enum ConsoleDensity: String, CaseIterable {
    case compact = "Compact", balanced = "Balanced", large = "Large"

    func tileHeight(compactWindow: Bool) -> CGFloat {
        switch self {
        case .compact: compactWindow ? 92 : 112
        case .balanced: compactWindow ? 112 : 144
        case .large: compactWindow ? 132 : 172
        }
    }

    var spacing: CGFloat { self == .compact ? 12 : 16 }
}

enum ConsoleAmbient: String, CaseIterable {
    case off = "Off", low = "Low", medium = "Medium", high = "High"

    var intensity: Double {
        switch self {
        case .off: 0
        case .low: 0.43
        case .medium: 0.74
        case .high: 0.95
        }
    }
}

enum ConsoleSoundPack: String, CaseIterable {
    case studio = "Studio", soft = "Soft"
}

enum ConsoleGlyphStyle: String, CaseIterable {
    case auto = "Auto", playStation = "PlayStation", xbox = "Xbox", nintendo = "Nintendo", keyboard = "Keyboard"

    func label(for control: ConsolePromptControl) -> String? {
        switch (self, control) {
        case (.auto, _): nil
        case (.keyboard, .confirm): "↵"
        case (.keyboard, .back): "Esc"
        case (.keyboard, .details): "Space"
        case (.keyboard, .secondary): "O"
        case (.keyboard, .previousTab): "Q"
        case (.keyboard, .nextTab): "E"
        case (.keyboard, .menu): "M"
        case (.keyboard, .context): "M"
        case (.keyboard, .guide): "C"
        case (.playStation, .confirm): "×"
        case (.playStation, .back): "○"
        case (.playStation, .details): "□"
        case (.playStation, .secondary): "△"
        case (.playStation, .previousTab): "L1"
        case (.playStation, .nextTab): "R1"
        case (.playStation, .menu): "Options"
        case (.playStation, .context): "Create"
        case (.playStation, .guide): "PS"
        case (.xbox, .confirm), (.nintendo, .back): "A"
        case (.xbox, .back), (.nintendo, .confirm): "B"
        case (.xbox, .details), (.nintendo, .secondary): "X"
        case (.xbox, .secondary), (.nintendo, .details): "Y"
        case (.xbox, .previousTab): "LB"
        case (.xbox, .nextTab): "RB"
        case (.xbox, .menu): "Menu"
        case (.xbox, .context): "View"
        case (.xbox, .guide): "Xbox"
        case (.nintendo, .previousTab): "L"
        case (.nintendo, .nextTab): "R"
        case (.nintendo, .menu): "+"
        case (.nintendo, .context): "−"
        case (.nintendo, .guide): "Home"
        }
    }
}

enum ConsoleUpdateChannel: String, CaseIterable {
    case stable = "Stable", beta = "Beta", nightly = "Nightly"
}

@MainActor
final class ConsolePreferences: ObservableObject {
    static let shared = ConsolePreferences()
    private let defaults: UserDefaults

    @Published var density: ConsoleDensity { didSet { defaults.set(density.rawValue, forKey: "console.density") } }
    @Published var ambient: ConsoleAmbient { didSet { defaults.set(ambient.rawValue, forKey: "console.ambient") } }
    @Published var glyphs: ConsoleGlyphStyle { didSet { defaults.set(glyphs.rawValue, forKey: "console.glyphs") } }
    @Published var channel: ConsoleUpdateChannel { didSet { defaults.set(channel.rawValue, forKey: "console.updateChannel") } }
    @Published var bootAnimation: Bool { didSet { defaults.set(bootAnimation, forKey: "console.bootAnimation") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "console.navigationHaptics") } }
    @Published var verboseHUD: Bool { didSet { defaults.set(verboseHUD, forKey: "console.verboseHUD") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        density = ConsoleDensity(rawValue: defaults.string(forKey: "console.density") ?? "") ?? .balanced
        ambient = ConsoleAmbient(rawValue: defaults.string(forKey: "console.ambient") ?? "") ?? .medium
        glyphs = ConsoleGlyphStyle(rawValue: defaults.string(forKey: "console.glyphs") ?? "") ?? .auto
        channel = ConsoleUpdateChannel(rawValue: defaults.string(forKey: "console.updateChannel") ?? "") ?? .stable
        bootAnimation = defaults.object(forKey: "console.bootAnimation") as? Bool ?? true
        haptics = defaults.bool(forKey: "console.navigationHaptics")
        verboseHUD = defaults.object(forKey: "console.verboseHUD") as? Bool ?? true
    }

    func reset() {
        density = .balanced
        ambient = .medium
        glyphs = .auto
        channel = .stable
        bootAnimation = true
        haptics = false
        verboseHUD = true
    }
}
