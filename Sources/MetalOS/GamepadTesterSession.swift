import Foundation
import Combine
import GameController

/// Owns the sampler across SwiftUI redraws. Controller activity must not recreate its timer.
@MainActor
final class GamepadTesterSession: ObservableObject {
    @Published private(set) var snapshot = GamepadSnapshot()
    @Published private(set) var recentButtons: Set<String> = []
    @Published private(set) var sampleTime = Date()
    @Published private(set) var eventCount = 0
    private var selectedID: String?
    private var subscription: AnyCancellable?
    private var timer: AnyCancellable?
    private var pressedUntil: [String: Date] = [:]

    func select(_ id: String?, manager: ControllerManager) {
        stop()
        selectedID = id
        snapshot = GamepadSnapshot(manager.controller(id: id)?.extendedGamepad)
        subscription = manager.$inputSnapshots.sink { [weak self] samples in
            guard let self, let id = self.selectedID, let value = samples[id] else { return }
            self.receive(value, at: Date())
        }
        // Fallback polling also catches held inputs on entry. Its publisher lives in this
        // StateObject, rather than being recreated by every parent controller update.
        timer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect().sink { [weak self, weak manager] now in
            guard let self, let manager else { return }
            self.sample(GamepadSnapshot(manager.controller(id: self.selectedID)?.extendedGamepad), at: now)
        }
    }
    func receive(_ value: GamepadSnapshot, at time: Date) {
        eventCount += 1
        for (name, pressed) in value.buttons where pressed { pressedUntil[name] = time.addingTimeInterval(0.14) }
        sample(value, at: time)
    }
    func sample(_ value: GamepadSnapshot, at time: Date) {
        snapshot = value
        pressedUntil = pressedUntil.filter { $0.value > time }
        recentButtons = Set(pressedUntil.keys)
        sampleTime = time
    }
    func stop() {
        subscription?.cancel(); subscription = nil
        timer?.cancel(); timer = nil
        selectedID = nil
        pressedUntil = [:]; recentButtons = []; eventCount = 0
    }
}
