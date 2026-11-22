import SwiftUI

enum ConsoleDesign {
    enum Palette {
        static let canvas = Color(red: 0.047, green: 0.051, blue: 0.063)
        static let panel = Color(red: 0.090, green: 0.098, blue: 0.118)
        static let text = Color.white.opacity(0.96)
        static let secondaryText = Color.white.opacity(0.74)
        static let border = Color.white.opacity(0.16)
        static let focus = Color(red: 0.82, green: 0.89, blue: 1)
    }

    enum Typography {
        static let display = Font.system(size: 64, weight: .semibold)
        static let title = Font.system(size: 38, weight: .semibold)
        static let heading = Font.system(size: 26, weight: .semibold)
        static let body = Font.system(size: 22)
        static let action = Font.system(size: 20, weight: .semibold)
        static let metadata = Font.system(size: 16, weight: .medium, design: .monospaced)
    }

    enum Space {
        static let badge: CGFloat = 8
        static let related: CGFloat = 12
        static let gutter: CGFloat = 24
        static let section: CGFloat = 36
        static let screenInset: CGFloat = 56
        static let minimumControlHeight: CGFloat = 56
    }

    enum Radius {
        static let badge: CGFloat = 10
        static let control: CGFloat = 16
        static let card: CGFloat = 24
        static let overlay: CGFloat = 32
    }

    enum Focus {
        static let scale: CGFloat = 1.05
        static let ringWidth: CGFloat = 2
        static let shadowRadius: CGFloat = 18
    }

    enum Artwork {
        static let blurRadius: CGFloat = 56
        static let scrimOpacity = 0.58
    }
}

enum ConsoleSurface {
    case matte, glass
}

struct ConsoleCard<Content: View>: View {
    var surface: ConsoleSurface = .glass
    var cornerRadius: CGFloat = ConsoleDesign.Radius.card
    var padding: CGFloat = ConsoleDesign.Space.gutter
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .foregroundStyle(ConsoleDesign.Palette.text)
            .padding(padding)
            .background {
                if surface == .glass && !reduceTransparency {
                    shape.fill(.ultraThinMaterial)
                        .overlay { shape.fill(ConsoleDesign.Palette.panel.opacity(0.72)) }
                } else {
                    shape.fill(ConsoleDesign.Palette.panel)
                }
            }
            .overlay {
                shape.strokeBorder(ConsoleDesign.Palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .environment(\.colorScheme, .dark)
    }
}

struct ConsoleFocusEffect: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let accent: Color
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let animate = !reduceMotion && !feedback.motionReduced

        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? ConsoleDesign.Palette.focus : .clear,
                        lineWidth: ConsoleDesign.Focus.ringWidth
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: isFocused ? accent.opacity(0.35) : .clear,
                radius: ConsoleDesign.Focus.shadowRadius, y: 6
            )
            .scaleEffect(isFocused && animate ? ConsoleDesign.Focus.scale : 1)
            .zIndex(isFocused ? 1 : 0)
            .animation(animate ? feedback.focusAnimation : nil, value: isFocused)
    }
}

extension View {
    func consoleFocusEffect(
        _ isFocused: Bool,
        cornerRadius: CGFloat = ConsoleDesign.Radius.control,
        accent: Color = ConsoleDesign.Palette.focus
    ) -> some View {
        modifier(ConsoleFocusEffect(isFocused: isFocused, cornerRadius: cornerRadius, accent: accent))
    }
}

struct FocusableButton<ID: Hashable, Label: View>: View {
    let id: ID
    let focus: FocusState<ID?>.Binding
    var isScopeActive = true
    var accent = ConsoleDesign.Palette.focus
    var horizontalPadding = ConsoleDesign.Space.gutter
    var prominent = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            focus.wrappedValue = id
            action()
        } label: {
            if prominent {
                controlLabel
                    .foregroundStyle(ConsoleDesign.Palette.canvas)
                    .background(
                        ConsoleDesign.Palette.focus,
                        in: RoundedRectangle(cornerRadius: ConsoleDesign.Radius.control, style: .continuous)
                    )
            } else {
                ConsoleCard(cornerRadius: ConsoleDesign.Radius.control, padding: 0) {
                    controlLabel
                }
            }
        }
        .buttonStyle(ConsoleButtonStyle())
        .focusable(isEnabled && isScopeActive)
        .focused(focus, equals: id)
        .focusEffectDisabled()
        .consoleFocusEffect(isEnabled && isScopeActive && focus.wrappedValue == id, accent: accent)
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isScopeActive)
    }

    private var controlLabel: some View {
        label()
            .font(ConsoleDesign.Typography.action)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: ConsoleDesign.Space.minimumControlHeight,
                   minHeight: ConsoleDesign.Space.minimumControlHeight)
            .contentShape(Rectangle())
    }
}
