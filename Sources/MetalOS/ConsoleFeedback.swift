import AppKit
import SwiftUI

enum NavigationCue: CaseIterable, Hashable {
    case move, confirm, back, open, toggle
    static func command(_ command: String) -> NavigationCue? {
        switch command {
        case "left", "right", "up", "down", "previous", "next": .move
        case "confirm": .confirm
        case "back": .back
        case "menu", "context", "details": .open
        case "favorite": .toggle
        default: nil
        }
    }
}
/// Original, short synthesized cues; no system alert or console audio files are used.
enum NavigationTone {
    static let sampleRate = 24_000
    static func wave(_ cue: NavigationCue) -> Data {
        let duration: Double
        switch cue {
        case .move: duration = 0.038
        case .confirm: duration = 0.13
        case .back: duration = 0.085
        case .open: duration = 0.105
        case .toggle: duration = 0.075
        }
        let frames = Int(duration * Double(sampleRate))
        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let t = Double(frame) / Double(sampleRate)
            let attack = min(t / 0.003, 1)
            let release = min((duration - t) / 0.012, 1)
            let envelope = attack * release * exp(-t * (cue == .move ? 65 : 22))
            let signal: Double
            switch cue {
            case .move: signal = sin(2 * .pi * (1100 * t - 1600 * t * t)) * 0.16
            case .confirm:
                signal = sin(2 * .pi * 660 * t) * 0.13 + (t > 0.025 ? sin(2 * .pi * 990 * (t - 0.025)) * 0.1 : 0)
            case .back: signal = sin(2 * .pi * (760 * t - 1800 * t * t)) * 0.18
            case .open: signal = sin(2 * .pi * (520 * t + 1500 * t * t)) * 0.16
            case .toggle: signal = (sin(2 * .pi * 880 * t) + sin(2 * .pi * 1320 * t) * 0.35) * 0.13
            }
            var value = Int16(max(-1, min(1, signal * envelope)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func word(_ number: UInt16) { var number = number.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        func dword(_ number: UInt32) { var number = number.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); dword(UInt32(36 + samples.count)); data.append(Data("WAVEfmt ".utf8))
        dword(16); word(1); word(1); dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 2)); word(2); word(16)
        data.append(Data("data".utf8)); dword(UInt32(samples.count)); data.append(samples)
        return data
    }
}
@MainActor
final class ConsoleFeedback: ObservableObject {
    static let shared = ConsoleFeedback()
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "console.sounds"); if !soundsEnabled { sounds.values.forEach { $0.stop() } } } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "console.soundVolume") } }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "console.reduceMotion") } }
    private let defaults: UserDefaults
    private var sounds: [NavigationCue: NSSound] = [:]
    private var lastPlay: [NavigationCue: TimeInterval] = [:]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundsEnabled = defaults.object(forKey: "console.sounds") as? Bool ?? true
        let saved = defaults.object(forKey: "console.soundVolume") as? Double ?? 0.35
        volume = saved.isFinite ? min(max(saved, 0), 1) : 0.35
        reduceMotion = defaults.bool(forKey: "console.reduceMotion")
    }
    var motionReduced: Bool { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var focusAnimation: Animation? { motionReduced ? nil : .spring(response: 0.24, dampingFraction: 0.84) }
    var pageAnimation: Animation? { motionReduced ? nil : .easeInOut(duration: 0.22) }
    var volumeText: String { "\(Int((min(max(volume, 0), 1) * 100).rounded()))%" }
    func adjustVolume(_ delta: Double) { volume = min(max(volume + delta, 0), 1) }
    func respond(to command: String) { if let cue = NavigationCue.command(command) { play(cue) } }
    func play(_ cue: NavigationCue) {
        guard soundsEnabled, volume.isFinite, volume > 0 else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - (lastPlay[cue] ?? 0) >= (cue == .move ? 0.07 : 0.035) else { return }
        lastPlay[cue] = now
        if sounds[cue] == nil { sounds[cue] = NSSound(data: NavigationTone.wave(cue)) }
        guard let sound = sounds[cue] else { return }
        sound.stop(); sound.volume = Float(min(volume, 1)); sound.play()
    }
}
struct ConsoleButtonStyle: ButtonStyle {
    @ObservedObject private var feedback = ConsoleFeedback.shared
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !feedback.motionReduced ? 0.97 : 1)
            .animation(feedback.focusAnimation, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in if pressed { feedback.play(.confirm) } }
    }
}
private struct ConsoleFocusModifier: ViewModifier {
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var controller = ControllerManager.shared
    @ObservedObject private var overlay = GameOverlayController.shared
    @Environment(\.consoleFocusScopeID) private var scopeID
    @Environment(\.consoleOverlayFocus) private var overlayFocus
    let selected: Bool
    let cornerRadius: CGFloat
    let scale: CGFloat
    private var isFocused: Bool {
        selected && (overlayFocus || (!overlay.isVisible && scopeID == controller.activeInputScopeID))
    }
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isFocused ? studioAccent.opacity(0.12) : .clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isFocused ? studioAccent.opacity(0.84) : .clear, lineWidth: isFocused ? 1.2 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: isFocused ? studioAccent.opacity(0.22) : .clear, radius: isFocused ? 13 : 0)
            .brightness(isFocused ? 0.02 : 0)
            .scaleEffect(isFocused && !feedback.motionReduced ? scale : 1)
            .zIndex(isFocused ? 10 : 0)
            .animation(feedback.focusAnimation, value: isFocused)
    }
}
private struct ConsoleMotionModifier: ViewModifier {
    @ObservedObject private var feedback = ConsoleFeedback.shared
    func body(content: Content) -> some View {
        content.transaction { transaction in
            if feedback.motionReduced { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
}
extension View {
    func consoleFocus(_ selected: Bool, cornerRadius: CGFloat = 12, scale: CGFloat = 1.035) -> some View {
        modifier(ConsoleFocusModifier(selected: selected, cornerRadius: cornerRadius, scale: scale))
    }
    func consoleMotion() -> some View { modifier(ConsoleMotionModifier()) }
}

private struct ConsoleFocusScopeKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct ConsoleOverlayFocusKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var consoleFocusScopeID: UUID? {
        get { self[ConsoleFocusScopeKey.self] }
        set { self[ConsoleFocusScopeKey.self] = newValue }
    }
    var consoleOverlayFocus: Bool {
        get { self[ConsoleOverlayFocusKey.self] }
        set { self[ConsoleOverlayFocusKey.self] = newValue }
    }
}

// Blur only the presenting surface; the sheet stays sharp in its own window.
private struct ConsoleModalBackdrop: ViewModifier {
    @ObservedObject private var feedback = ConsoleFeedback.shared
    let presented: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: presented ? 14 : 0)
            .overlay { Color.black.opacity(presented ? 0.16 : 0).allowsHitTesting(false) }
            .animation(feedback.pageAnimation, value: presented)
    }
}
private struct ConsoleModalEntrance: ViewModifier {
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @State private var appeared = false
    func body(content: Content) -> some View {
        content
            .opacity(appeared || feedback.motionReduced ? 1 : 0)
            .scaleEffect(appeared || feedback.motionReduced ? 1 : 0.96)
            .offset(y: appeared || feedback.motionReduced ? 0 : 12)
            .onAppear { withAnimation(feedback.pageAnimation) { appeared = true } }
    }
}
extension View {
    func consoleModalBackdrop(_ presented: Bool) -> some View {
        modifier(ConsoleModalBackdrop(presented: presented))
    }
    func consoleSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        consoleModalBackdrop(isPresented.wrappedValue)
            .sheet(isPresented: isPresented, onDismiss: onDismiss) {
                content().modifier(ConsoleModalEntrance())
            }
    }
}
