import SwiftUI

enum ConsoleDesign {
    enum Palette {
        static let canvas = Color(red: 0.047, green: 0.051, blue: 0.063)
        static let panel = Color(red: 0.090, green: 0.098, blue: 0.118)
        static let text = Color.white.opacity(0.96)
        static let secondaryText = Color.white.opacity(0.74)
        static let border = Color.white.opacity(0.16)
        static var focus = Color.white
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

enum ConsoleMotion {
    static let focusSpring = Animation.spring(response: 0.34, dampingFraction: 0.88)
    static let ribbonSpring = Animation.spring(response: 0.44, dampingFraction: 0.91)
    static let zoneSpring = Animation.spring(response: 0.52, dampingFraction: 0.9)
    static let crossfadeDuration = 0.52
    static let browseDebounceNanoseconds: UInt64 = 100_000_000
    static let focusBreathDuration = 2.7
    static let focusSweepDuration = 5.2
    static let focusRingWidth: CGFloat = 2.5
    static let focusGlowRadius: CGFloat = 20
    static let tileFocusScale: CGFloat = 1.15
    static let tileIdleOpacity = 0.78
    static let tileIdleSaturation = 0.84
    static let activityFocusScale: CGFloat = 1.025
    static let ambientDriftDuration = 32.0
}

struct ConsoleSignatureFocusRing<S: InsettableShape>: View {
    let shape: S
    let isFocused: Bool

    @State private var breathing = false
    @State private var sweepPhase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ringColor: Color { ConsoleDesign.Palette.focus }
    private var motionEnabled: Bool { !reduceMotion }

    private var sweep: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.72), location: 0.11),
                .init(color: .clear, location: 0.23),
                .init(color: .clear, location: 1)
            ]),
            center: .center,
            startAngle: .degrees(sweepPhase * 360),
            endAngle: .degrees(sweepPhase * 360 + 360)
        )
    }

    var body: some View {
        ZStack {
            shape.strokeBorder(ringColor.opacity(isFocused ? 0.98 : 0), lineWidth: ConsoleMotion.focusRingWidth)
            shape.strokeBorder(sweep, lineWidth: 1.15).opacity(isFocused && motionEnabled ? 0.62 : 0)
        }
        .shadow(color: ringColor.opacity(isFocused ? (breathing ? 0.32 : 0.18) : 0),
                radius: isFocused ? (breathing ? ConsoleMotion.focusGlowRadius : ConsoleMotion.focusGlowRadius * 0.72) : 0)
        .animation(motionEnabled ? ConsoleMotion.focusSpring : nil, value: isFocused)
        .onAppear(perform: startAmbientRingMotion)
        .onChange(of: isFocused) { _, focused in
            guard focused else {
                breathing = false
                sweepPhase = 0
                return
            }
            startAmbientRingMotion()
        }
    }

    private func startAmbientRingMotion() {
        guard isFocused, motionEnabled else { return }
        withAnimation(.easeInOut(duration: ConsoleMotion.focusBreathDuration).repeatForever(autoreverses: true)) {
            breathing = true
        }
        withAnimation(.linear(duration: ConsoleMotion.focusSweepDuration).repeatForever(autoreverses: false)) {
            sweepPhase = 1
        }
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
