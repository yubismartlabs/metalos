import AVFoundation
import AppKit
import Combine

private enum ConsoleSoundCue: String, CaseIterable, Hashable {
    case boot, login, focus, confirm, back, boundary, tab, overlayOpen, overlayClose, slider, notification
}

/// Main-thread observable settings facade. All graph operations and playback are serialized off the UI thread.
@MainActor
final class UISoundManager: ObservableObject {
    static let shared = UISoundManager()

    @Published private(set) var isSFXEnabled = false
    @Published private(set) var sfxVolume: Float = 0.45
    @Published private(set) var isAmbientMusicEnabled = false
    @Published private(set) var ambientVolume: Float = 0.35
    @Published private(set) var soundTheme = "Next-Gen Minimal"

    private let engineCore = ConsoleAudioEngineCore()
    private var focusObserver: NSObjectProtocol?
    private var focusedGameID: String?
    private var focusedAudioURL: URL?
    private var suspended = false

    private init() {
        engineCore.start()
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.suspended else { return }
                self.resumeFromGame()
            }
        }
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    var soundThemeName: String {
        get { soundTheme }
        set {
            soundTheme = newValue
            engineCore.setTheme(newValue)
            engineCore.setSFX(enabled: isSFXEnabled && newValue != "Silent", volume: sfxVolume)
        }
    }

    static var soundEffectsEnabled: Bool {
        get { shared.isSFXEnabled }
        set {
            shared.isSFXEnabled = newValue
            shared.engineCore.setSFX(enabled: newValue && shared.soundTheme != "Silent", volume: shared.sfxVolume)
        }
    }
    static var soundEffectsVolume: Float {
        get { shared.sfxVolume }
        set {
            shared.sfxVolume = min(1, max(0, newValue))
            shared.engineCore.setSFX(enabled: shared.isSFXEnabled && shared.soundTheme != "Silent", volume: shared.sfxVolume)
        }
    }
    static var ambientMusicEnabled: Bool {
        get { shared.isAmbientMusicEnabled }
        set {
            shared.isAmbientMusicEnabled = newValue
            shared.engineCore.setAmbient(enabled: newValue, volume: shared.ambientVolume)
            if newValue, let focusedGameID = shared.focusedGameID {
                shared.engineCore.requestGameFocus(focusedGameID, audioURL: shared.focusedAudioURL)
            }
        }
    }
    static var ambientMusicVolume: Float {
        get { shared.ambientVolume }
        set {
            shared.ambientVolume = min(1, max(0, newValue))
            shared.engineCore.setAmbient(enabled: shared.isAmbientMusicEnabled, volume: shared.ambientVolume)
        }
    }
    static var ambientMusicHook: ((String) -> Void)?

    static func playBootChime() { shared.play(.boot) }
    static func playLoginConfirm() { shared.play(.login) }
    static func playFocusMove() { shared.play(.focus) }
    static func playConfirm() { shared.play(.confirm) }
    static func playBack() { shared.play(.back) }
    static func playBoundaryBump() { shared.play(.boundary) }
    static func playTabSwitch() { shared.play(.tab) }
    static func playOverlayOpen() { shared.play(.overlayOpen) }
    static func playOverlayClose() { shared.play(.overlayClose) }
    static func playSliderTick() { shared.play(.slider) }
    static func playNotificationToast() { shared.play(.notification) }

    static func setOverlayActive(_ active: Bool) { shared.engineCore.setOverlayActive(active) }

    static func onGameFocusChanged(gameID: String, audioURL: URL? = nil) {
        shared.focusedGameID = gameID
        shared.focusedAudioURL = audioURL
        ambientMusicHook?(gameID)
        shared.engineCore.requestGameFocus(gameID, audioURL: audioURL)
    }

    static func onGameFocusChanged(_ gameID: String) {
        onGameFocusChanged(gameID: gameID)
    }

    static func suspendForGameLaunch() { shared.suspendForGameLaunch() }
    static func resumeFromGame() { shared.resumeFromGame() }
    static func recoverAfterSystemWake() {
        shared.engineCore.recoverAfterSystemWake()
    }
    static func stopForExit() {
        shared.suspended = true
        shared.engineCore.stopForExit()
    }

    private func play(_ cue: ConsoleSoundCue) { engineCore.play(cue) }

    private func suspendForGameLaunch() {
        guard !suspended else { return }
        suspended = true
        engineCore.suspendForGameLaunch()
    }

    private func resumeFromGame() {
        guard suspended else { return }
        suspended = false
        engineCore.resumeFromGame()
        if let focusedGameID { engineCore.requestGameFocus(focusedGameID, audioURL: focusedAudioURL) }
    }
}

/// Owns AVAudioEngine on a serial control queue so UI actions never perform graph work or disk reads.
private final class ConsoleAudioEngineCore: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "com.metalos.console.audio", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "com.metalos.console.audio.decode", qos: .utility)
    private let sampleRate = 48_000.0
    private let sfxNodeCount = 6

    private var sfxMixer = AVAudioMixerNode()
    private var musicEQ = AVAudioUnitEQ(numberOfBands: 1)
    private var musicMixer = AVAudioMixerNode()
    private var sfxPool: [AVAudioPlayerNode] = []
    private var musicDecks: [AVAudioPlayerNode] = []
    private var deckBuffers: [AVAudioPCMBuffer?] = [nil, nil]
    private var deckTrackIDs: [String?] = [nil, nil]
    private var sfxBuffers: [String: [ConsoleSoundCue: [AVAudioPCMBuffer]]] = [:]
    private var ambientFallback: AVAudioPCMBuffer?
    private var graphBuilt = false
    private var started = false
    private var suspended = false
    private var sfxEnabled = false
    private var sfxVolume: Float = 0.45
    private var musicEnabled = false
    private var musicVolume: Float = 0.35
    private var activeTheme = "Next-Gen Minimal"
    private var activeDeck = 0
    private var activeTrackID: String?
    private var focusedGameID: String?
    private var focusedAudioURL: URL?
    private var overlayActive = false
    private var nextSFXNode = 0
    private var nextFocusVariant = 0
    private var lastFocusSoundTime: TimeInterval = 0
    private var focusDebounce: DispatchWorkItem?
    private var crossfadeToken: UInt64 = 0
    private var sfxRampToken: UInt64 = 0
    private var mixRampToken: UInt64 = 0
    private var observer: NSObjectProtocol?

    private var mixerFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)! }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.controlQueue.async { [weak self] in self?.restartForConfigurationChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.configureGraphIfNeeded()
            self.startEngineIfNeeded()
        }
    }

    func setSFX(enabled: Bool, volume: Float) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.sfxEnabled = enabled
            self.sfxVolume = min(1, max(0, volume))
            self.rampSFXMixer(to: enabled && !self.suspended ? self.sfxVolume : 0, duration: 0.12)
        }
    }

    func setTheme(_ theme: String) {
        controlQueue.async { [weak self] in self?.activeTheme = theme }
    }

    func setAmbient(enabled: Bool, volume: Float) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.musicEnabled = enabled
            self.musicVolume = min(1, max(0, volume))
            let target = enabled && !self.suspended ? self.musicVolume * self.duckGain : 0
            self.rampMusicMixer(to: target, duration: 0.22)
        }
    }

    func setOverlayActive(_ active: Bool) {
        controlQueue.async { [weak self] in
            guard let self, self.overlayActive != active else { return }
            self.overlayActive = active
            guard self.graphBuilt else { return }
            let band = self.musicEQ.bands[0]
            band.filterType = .lowPass
            band.bypass = false
            self.animate(duration: 0.24) { progress in
                let from = active ? 20_000.0 : 950.0
                let to = active ? 950.0 : 20_000.0
                band.frequency = Float(from + (to - from) * progress)
                if progress >= 1 { band.bypass = !active }
            }
            self.rampMusicMixer(to: self.musicEnabled && !self.suspended ? self.musicVolume * self.duckGain : 0, duration: 0.24)
        }
    }

    func play(_ cue: ConsoleSoundCue) {
        controlQueue.async { [weak self] in
            guard let self, self.sfxEnabled, !self.suspended, self.activeTheme != "Silent" else { return }
            self.configureGraphIfNeeded()
            self.startEngineIfNeeded()
            guard !self.sfxPool.isEmpty else { return }
            let node = self.sfxPool[self.nextSFXNode]
            self.nextSFXNode = (self.nextSFXNode + 1) % self.sfxPool.count
            var variant = 0
            if cue == .focus {
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastFocusSoundTime < 0.16 { self.nextFocusVariant = (self.nextFocusVariant + 1) % 3 }
                else { self.nextFocusVariant = 0 }
                self.lastFocusSoundTime = now
                variant = self.nextFocusVariant
            }
            guard let buffer = self.sfxBuffers[self.activeTheme]?[cue], !buffer.isEmpty else { return }
            node.volume = 1
            node.scheduleBuffer(buffer[min(variant, buffer.count - 1)], at: nil, options: [])
            if !node.isPlaying { node.play() }
        }
    }

    func requestGameFocus(_ gameID: String, audioURL: URL?) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.focusedGameID = gameID
            self.focusedAudioURL = audioURL
            self.focusDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.musicEnabled, !self.suspended else { return }
                self.loadAndCrossfade(gameID: gameID, audioURL: audioURL)
            }
            self.focusDebounce = work
            self.controlQueue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
        }
    }

    func suspendForGameLaunch() {
        controlQueue.async { [weak self] in
            guard let self, !self.suspended else { return }
            self.suspended = true
            self.focusDebounce?.cancel()
            self.rampSFXMixer(to: 0, duration: 0.4)
            self.rampMusicMixer(to: 0, duration: 0.4) { [weak self] in
                guard let self else { return }
                self.engine.pause()
                self.started = false
            }
        }
    }

    func resumeFromGame() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.configureGraphIfNeeded()
            self.startEngineIfNeeded()
            self.restoreDeckPlayback()
            self.rampSFXMixer(to: self.sfxEnabled && self.activeTheme != "Silent" ? self.sfxVolume : 0, duration: 0.35)
            self.rampMusicMixer(to: self.musicEnabled ? self.musicVolume * self.duckGain : 0, duration: 0.55)
        }
    }

    func recoverAfterSystemWake() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.configureGraphIfNeeded()
            self.engine.stop()
            self.engine.reset()
            self.started = false
            self.startEngineIfNeeded()
            self.restoreDeckPlayback()
            self.rampSFXMixer(to: self.sfxEnabled && self.activeTheme != "Silent" ? self.sfxVolume : 0, duration: 0.18)
            self.rampMusicMixer(to: self.musicEnabled ? self.musicVolume * self.duckGain : 0, duration: 0.35)
        }
    }

    func stopForExit() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.suspended = true
            self.engine.stop()
            self.engine.reset()
            self.started = false
        }
    }

    private var duckGain: Float { overlayActive ? 0.63 : 1 }

    private func configureGraphIfNeeded() {
        guard !graphBuilt else { return }
        sfxMixer = AVAudioMixerNode()
        musicEQ = AVAudioUnitEQ(numberOfBands: 1)
        musicMixer = AVAudioMixerNode()
        engine.attach(sfxMixer)
        engine.attach(musicEQ)
        engine.attach(musicMixer)
        engine.connect(sfxMixer, to: engine.mainMixerNode, format: nil)
        engine.connect(musicEQ, to: musicMixer, format: nil)
        engine.connect(musicMixer, to: engine.mainMixerNode, format: nil)

        let format = mixerFormat
        sfxPool = (0..<sfxNodeCount).map { _ in
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: sfxMixer, format: format)
            return node
        }
        musicDecks = (0..<2).map { _ in
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: musicEQ, format: format)
            node.volume = 0
            return node
        }
        let band = musicEQ.bands[0]
        band.filterType = .lowPass
        band.frequency = 20_000
        band.bypass = true
        musicEQ.globalGain = 0
        sfxMixer.outputVolume = 0
        musicMixer.outputVolume = 0
        ambientFallback = synthesizeAmbient(format: format)
        sfxBuffers = synthesizeSoundThemes(format: format)
        loadBundledSFX(format: format)
        graphBuilt = true
    }

    private func startEngineIfNeeded() {
        guard !started, !suspended else { return }
        do {
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    private func restartForConfigurationChange() {
        guard graphBuilt else { return }
        let wasRunning = !suspended
        engine.stop()
        engine.reset()
        started = false
        guard wasRunning else { return }
        startEngineIfNeeded()
        restoreDeckPlayback()
        rampSFXMixer(to: sfxEnabled && activeTheme != "Silent" ? sfxVolume : 0, duration: 0.15)
        rampMusicMixer(to: musicEnabled ? musicVolume * duckGain : 0, duration: 0.25)
    }

    private func restoreDeckPlayback() {
        guard started else { return }
        for index in musicDecks.indices {
            let node = musicDecks[index]
            guard let buffer = deckBuffers[index], deckTrackIDs[index] != nil else { continue }
            node.stop()
            node.scheduleBuffer(buffer, at: nil, options: [.loops])
            node.play()
        }
    }

    private func scheduleFocusRequest(_ gameID: String, audioURL: URL?) {
        focusDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.musicEnabled, !self.suspended else { return }
            self.loadAndCrossfade(gameID: gameID, audioURL: audioURL)
        }
        focusDebounce = work
        controlQueue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    private func loadAndCrossfade(gameID: String, audioURL: URL?) {
        let trackID = audioURL?.absoluteString ?? "system-home-ambient"
        if deckTrackIDs[activeDeck] == trackID, musicDecks[activeDeck].isPlaying { return }
        let fallback = ambientFallback
        let targetFormat = mixerFormat
        decodeQueue.async { [weak self] in
            let loaded = audioURL.flatMap { Self.readAudioBuffer(url: $0, targetFormat: targetFormat) } ?? fallback
            guard let loaded else { return }
            self?.controlQueue.async { [weak self] in
                guard let self, self.musicEnabled, !self.suspended, self.focusedGameID == gameID else { return }
                self.beginCrossfade(trackID: trackID, buffer: loaded)
            }
        }
    }

    private func beginCrossfade(trackID: String, buffer: AVAudioPCMBuffer) {
        if !started {
            startEngineIfNeeded()
            guard started else { return }
        }
        if deckTrackIDs[activeDeck] == trackID, musicDecks[activeDeck].isPlaying { return }
        let targetDeck = 1 - activeDeck
        let oldDeck = 1 - targetDeck
        crossfadeToken &+= 1
        let token = crossfadeToken
        let targetNode = musicDecks[targetDeck]
        targetNode.stop()
        targetNode.volume = 0
        targetNode.scheduleBuffer(buffer, at: nil, options: [.loops])
        targetNode.play()
        deckBuffers[targetDeck] = buffer
        deckTrackIDs[targetDeck] = trackID
        let initialA = max(0, Double(musicDecks[0].volume))
        let initialB = max(0, Double(musicDecks[1].volume))
        let startAngle: Double
        var angle = atan2(initialB, initialA)
        if initialA + initialB < 0.01 { angle = activeDeck == 0 ? 0 : .pi / 2 }
        startAngle = angle
        let targetAngle = targetDeck == 0 ? 0.0 : Double.pi / 2
        activeDeck = targetDeck
        activeTrackID = trackID
        animate(duration: 1.5, shouldContinue: { [weak self] in self?.crossfadeToken == token }) { [weak self] progress in
            guard let self else { return }
            angle = startAngle + (targetAngle - startAngle) * progress
            if progress >= 1 { angle = targetAngle }
            self.musicDecks[0].volume = Float(cos(angle))
            self.musicDecks[1].volume = Float(sin(angle))
            if progress >= 1, self.crossfadeToken == token {
                self.musicDecks[oldDeck].stop()
                self.deckBuffers[oldDeck] = nil
                self.deckTrackIDs[oldDeck] = nil
            }
        }
        rampMusicMixer(to: musicVolume * duckGain, duration: 0.22)
    }

    private func rampSFXMixer(to target: Float, duration: TimeInterval) {
        guard graphBuilt else { return }
        sfxRampToken &+= 1
        let token = sfxRampToken
        let start = sfxMixer.outputVolume
        animate(duration: duration, shouldContinue: { [weak self] in self?.sfxRampToken == token }) { [weak self] progress in
            guard let self else { return }
            self.sfxMixer.outputVolume = start + (target - start) * Float(progress)
        }
    }

    private func rampMusicMixer(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard graphBuilt else { completion?(); return }
        mixRampToken &+= 1
        let token = mixRampToken
        let start = musicMixer.outputVolume
        animate(duration: duration, shouldContinue: { [weak self] in self?.mixRampToken == token }) { [weak self] progress in
            guard let self else { return }
            self.musicMixer.outputVolume = start + (target - start) * Float(progress)
            if progress >= 1 { completion?() }
        }
    }

    private func animate(
        duration: TimeInterval,
        shouldContinue: @escaping () -> Bool = { true },
        update: @escaping (Double) -> Void
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        func step() {
            guard shouldContinue() else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let progress = duration <= 0 ? 1 : min(1, elapsed / duration)
            update(progress)
            if progress < 1 { controlQueue.asyncAfter(deadline: .now() + .milliseconds(20), execute: step) }
        }
        step()
    }

    private func loadBundledSFX(format: AVAudioFormat) {
        let names: [(ConsoleSoundCue, String)] = [
            (.boot, "boot"), (.login, "login"), (.focus, "focus"), (.confirm, "confirm"),
            (.back, "back"), (.boundary, "boundary"), (.tab, "tab"),
            (.overlayOpen, "overlay-open"), (.overlayClose, "overlay-close"), (.slider, "slider"),
            (.notification, "notification")
        ]
        for theme in ["Next-Gen Minimal", "Classic Subtle"] {
            for (cue, basename) in names {
                guard let url = Self.bundledAudioURL(named: "\(basename)-\(Self.themeSlug(theme))")
                    ?? Self.bundledAudioURL(named: basename),
                      let buffer = Self.readAudioBuffer(url: url, targetFormat: format) else { continue }
                sfxBuffers[theme, default: [:]][cue] = cue == .focus ? [buffer, buffer, buffer] : [buffer]
            }
        }
    }

    private func synthesizeSoundThemes(format: AVAudioFormat) -> [String: [ConsoleSoundCue: [AVAudioPCMBuffer]]] {
        var output: [String: [ConsoleSoundCue: [AVAudioPCMBuffer]]] = [:]
        for theme in ["Next-Gen Minimal", "Classic Subtle"] {
            var cues: [ConsoleSoundCue: [AVAudioPCMBuffer]] = [:]
            for cue in ConsoleSoundCue.allCases {
                if cue == .focus {
                    cues[cue] = [-0.02, 0, 0.02].compactMap { synthesize(cue, theme: theme, pitch: 1 + $0, format: format) }
                } else if let buffer = synthesize(cue, theme: theme, pitch: 1, format: format) {
                    cues[cue] = [buffer]
                }
            }
            output[theme] = cues
        }
        return output
    }

    private struct ToneComponent {
        let frequency: Double
        let start: Double
        let duration: Double
        let amplitude: Double
    }

    private func synthesize(_ cue: ConsoleSoundCue, theme: String, pitch: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let classic = theme == "Classic Subtle"
        let duration: Double
        let tones: [ToneComponent]
        switch cue {
        case .focus:
            duration = 0.045
            tones = [.init(frequency: 610, start: 0, duration: 0.04, amplitude: 0.18), .init(frequency: 910, start: 0.004, duration: 0.03, amplitude: 0.045)]
        case .confirm:
            duration = 0.2
            tones = [.init(frequency: 523, start: 0, duration: 0.13, amplitude: 0.2), .init(frequency: 784, start: 0.065, duration: 0.13, amplitude: 0.16)]
        case .back:
            duration = 0.17
            tones = [.init(frequency: 659, start: 0, duration: 0.1, amplitude: 0.14), .init(frequency: 440, start: 0.025, duration: 0.12, amplitude: 0.12)]
        case .boundary:
            duration = 0.11
            tones = [.init(frequency: 154, start: 0, duration: 0.1, amplitude: 0.19), .init(frequency: 270, start: 0.01, duration: 0.065, amplitude: 0.08)]
        case .boot:
            duration = 1.25
            tones = [220, 277, 330, 440].enumerated().map { .init(frequency: Double($0.element), start: Double($0.offset) * 0.06, duration: 1.12, amplitude: 0.09) }
        case .login:
            duration = 0.34
            tones = [.init(frequency: 440, start: 0, duration: 0.23, amplitude: 0.15), .init(frequency: 554, start: 0.035, duration: 0.24, amplitude: 0.12), .init(frequency: 659, start: 0.09, duration: 0.23, amplitude: 0.11)]
        case .tab:
            duration = 0.16
            tones = [.init(frequency: 470, start: 0, duration: 0.11, amplitude: 0.11), .init(frequency: 630, start: 0.025, duration: 0.12, amplitude: 0.11)]
        case .overlayOpen:
            duration = 0.24
            tones = [.init(frequency: 392, start: 0, duration: 0.2, amplitude: 0.1), .init(frequency: 587, start: 0.025, duration: 0.19, amplitude: 0.1)]
        case .overlayClose:
            duration = 0.2
            tones = [.init(frequency: 587, start: 0, duration: 0.11, amplitude: 0.08), .init(frequency: 392, start: 0.025, duration: 0.16, amplitude: 0.08)]
        case .slider:
            duration = 0.04
            tones = [.init(frequency: 930, start: 0, duration: 0.035, amplitude: 0.12)]
        case .notification:
            duration = 0.28
            tones = [.init(frequency: 740, start: 0, duration: 0.2, amplitude: 0.105), .init(frequency: 988, start: 0.075, duration: 0.2, amplitude: 0.075)]
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * format.sampleRate)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let frameCount = Int(buffer.frameLength)
        let gain = classic ? 0.78 : 1.0
        for channel in 0..<Int(format.channelCount) {
            let data = channels[channel]
            for frame in 0..<frameCount {
                let time = Double(frame) / format.sampleRate
                var value = 0.0
                for tone in tones where time >= tone.start && time <= tone.start + tone.duration {
                    let local = time - tone.start
                    let attackDuration = cue == .boot ? 0.18 : (cue == .focus || cue == .slider ? 0.002 : 0.008)
                    let attack = min(1, local / attackDuration)
                    let decay = exp(-5.5 * local / tone.duration)
                    let phase = 2 * Double.pi * tone.frequency * local * pitch
                    let pluck = sin(phase) + sin(phase * 2) * 0.12
                    value += pluck * tone.amplitude * attack * decay
                }
                data[frame] = Float(max(-0.95, min(0.95, value * gain)))
            }
        }
        return buffer
    }

    private func synthesizeAmbient(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 8.0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * format.sampleRate)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let frequencies = [110.0, 165.0, 220.0, 330.0]
        for channel in 0..<Int(format.channelCount) {
            let data = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / format.sampleRate
                let envelope = 0.82 + 0.18 * sin(2 * Double.pi * time / duration)
                var value = 0.0
                for (index, frequency) in frequencies.enumerated() {
                    let phase = 2 * Double.pi * frequency * time
                    let shimmer = 0.76 + 0.24 * sin(2 * Double.pi * (2 + Double(index)) * time / duration)
                    value += sin(phase) * shimmer / Double(frequencies.count)
                }
                data[frame] = Float(value * envelope * 0.035)
            }
        }
        return buffer
    }

    private static func bundledAudioURL(named name: String) -> URL? {
        for ext in ["caf", "wav"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
            if let url = Bundle.module.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    private static func readAudioBuffer(url: URL, targetFormat: AVAudioFormat? = nil) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceFormat = file.processingFormat
        guard file.length > 0, file.length < AVAudioFramePosition(Int32.max) else { return nil }
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: source) } catch { return nil }
        guard let targetFormat, targetFormat != sourceFormat,
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return source }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 8)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return source }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else { inputStatus.pointee = .noDataNow; return nil }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error ? source : output
    }

    private static func themeSlug(_ theme: String) -> String {
        theme.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
