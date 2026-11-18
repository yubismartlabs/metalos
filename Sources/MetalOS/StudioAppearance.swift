import SwiftUI

enum StudioTheme: String, CaseIterable, Identifiable {
    case emerald
    case blue
    case violet
    case rose
    case amber

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var accent: Color {
        switch self {
        case .emerald: Color(red: 0.20, green: 0.88, blue: 0.55)
        case .blue: Color(red: 0.20, green: 0.58, blue: 1.0)
        case .violet: Color(red: 0.68, green: 0.48, blue: 1.0)
        case .rose: Color(red: 1.0, green: 0.38, blue: 0.58)
        case .amber: Color(red: 1.0, green: 0.69, blue: 0.25)
        }
    }

    var background: Color {
        switch self {
        case .emerald: Color(red: 0.018, green: 0.055, blue: 0.043)
        case .blue: Color(red: 0.025, green: 0.043, blue: 0.09)
        case .violet: Color(red: 0.045, green: 0.03, blue: 0.085)
        case .rose: Color(red: 0.075, green: 0.025, blue: 0.052)
        case .amber: Color(red: 0.075, green: 0.047, blue: 0.018)
        }
    }
}

@MainActor
final class StudioAppearance: ObservableObject {
    static let shared = StudioAppearance()
    @Published var theme: StudioTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "studioTheme") }
    }

    var accent: Color { theme.accent }
    var background: Color { theme.background }

    private init() {
        theme = StudioTheme(rawValue: UserDefaults.standard.string(forKey: "studioTheme") ?? "emerald") ?? .emerald
    }
}

struct LiquidGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tint: Color = .white

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(StudioAppearance.shared.background.opacity(0.48), in: shape)
            .overlay {
                shape.fill(LinearGradient(
                    colors: [tint.opacity(0.105), .white.opacity(0.025), StudioAppearance.shared.accent.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.23), .white.opacity(0.055), StudioAppearance.shared.accent.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.19), radius: 18, y: 9)
    }
}

extension View {
    func liquidGlassSurface(cornerRadius: CGFloat = 18, tint: Color = .white) -> some View {
        modifier(LiquidGlassSurface(cornerRadius: cornerRadius, tint: tint))
    }
}
