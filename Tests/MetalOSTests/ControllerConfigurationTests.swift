import XCTest
import GameController
@testable import MetalOS

@MainActor
final class ControllerConfigurationTests: XCTestCase {
    func testTesterReadsOnlyTheSelectedControllerAndPreservesAnalogValues() throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(first.extendedGamepad)
        pad.buttonB.setValue(1)
        pad.buttonMenu.setValue(1)
        pad.leftTrigger.setValue(0.42)
        pad.leftThumbstick.setValueForXAxis(0.72, yAxis: -0.35)
        pad.dpad.setValueForXAxis(-1, yAxis: 1)
        let snapshot = GamepadSnapshot(pad)
        XCTAssertTrue(snapshot.buttons["B"] == true)
        XCTAssertTrue(snapshot.buttons["Menu"] == true)
        XCTAssertEqual(snapshot.leftTrigger, 0.42, accuracy: 0.01)
        XCTAssertEqual(snapshot.leftX, 0.72, accuracy: 0.01)
        XCTAssertEqual(snapshot.leftY, -0.35, accuracy: 0.01)
        XCTAssertEqual(snapshot.dpadX, -1)
        XCTAssertEqual(snapshot.dpadY, 1)
        XCTAssertFalse(GamepadSnapshot(second.extendedGamepad).buttons["B"] == true)
        XCTAssertEqual(GamepadSnapshot().leftTrigger, 0)
    }
    func testLightColorReadbackAndWraparound() {
        for (index, preset) in ControllerManager.lightPresets.enumerated() {
            XCTAssertEqual(ControllerManager.lightPresetIndex(preset.color), index)
        }
        XCTAssertNil(ControllerManager.lightPresetIndex(GCColor(red: 0.3, green: 0.2, blue: 0.1)))
        XCTAssertEqual(ControllerControlAction.cycle(0, delta: -1, count: 8), 7)
        XCTAssertEqual(ControllerControlAction.cycle(7, delta: 1, count: 8), 0)
        XCTAssertEqual(ControllerControlAction.cycle(nil, delta: 1, count: 8), 0)
    }
    func testDisconnectedAndInvalidConfigurationFailsSafely() {
        let manager = ControllerManager()
        let disconnected = GCController.withExtendedGamepad()
        XCTAssertFalse(manager.setPlayerNumber(-1, for: disconnected))
        XCTAssertFalse(manager.setPlayerNumber(4, for: disconnected))
        XCTAssertFalse(manager.setPlayerNumber(0, for: disconnected))
        XCTAssertFalse(manager.setLightColor(GCColor(red: 1, green: 0, blue: 0), for: disconnected))
        XCTAssertThrowsError(try manager.playHaptics(for: disconnected))
        XCTAssertNil(manager.controllerAt(index: -1))
        XCTAssertNil(manager.controllerAt(index: Int.max))
    }
    func testUnsupportedLightAndHapticsDoNotHidePlayerOrTester() {
        let device = ControllerStatus(id: "test", name: "Basic", productCategory: "", isAttached: false,
            batteryPercent: nil, batteryState: .unknown, playerNumber: nil, supportsMotion: false,
            supportsHaptics: false, supportsLight: false, hasOptionsButton: false, hasHomeButton: false)
        XCTAssertEqual(ControllerControlAction.available(for: device), [.lightingHelp, .player, .tester])
        XCTAssertTrue(ControllerControlAction.available(for: nil).isEmpty)
    }
    func testShortPressRemainsVisibleButReleaseIsNotHeld() {
        let session = GamepadTesterSession()
        let now = Date()
        var pressed = GamepadSnapshot()
        pressed.buttons["B"] = true
        session.receive(pressed, at: now)
        session.receive(GamepadSnapshot(), at: now.addingTimeInterval(0.01))
        XCTAssertTrue(session.recentButtons.contains("B"))
        XCTAssertNil(session.snapshot.buttons["B"], "The pause gesture must use raw input, not the visual latch")
        session.sample(GamepadSnapshot(), at: now.addingTimeInterval(0.2))
        XCTAssertFalse(session.recentButtons.contains("B"))
        XCTAssertEqual(session.eventCount, 2)
        session.stop()
        XCTAssertEqual(session.eventCount, 0)
    }

}
