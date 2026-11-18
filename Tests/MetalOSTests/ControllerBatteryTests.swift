import XCTest
@testable import MetalOS

final class ControllerBatteryTests: XCTestCase {
    func testUnknownOrInvalidReadingsDoNotBecomeEmptyBatteries() {
        XCTAssertNil(ControllerBatteryReading.percentage(level: nil, state: .unknown))
        XCTAssertNil(ControllerBatteryReading.percentage(level: -1, state: .discharging))
        XCTAssertNil(ControllerBatteryReading.percentage(level: 1.2, state: .full))
        XCTAssertNil(ControllerBatteryReading.percentage(level: .nan, state: .discharging))
        XCTAssertNil(ControllerBatteryReading.percentage(level: 0, state: .unknown))
        XCTAssertEqual(ControllerBatteryReading.percentage(level: 0, state: .discharging), 0)
    }
    func testReportedPercentagesAndChargingIndicator() {
        XCTAssertEqual(ControllerBatteryReading.percentage(level: 0.756, state: .discharging), 76)
        XCTAssertEqual(ControllerBatteryReading.percentage(level: 1, state: .full), 100)
        XCTAssertEqual(ControllerBatteryReading.symbol(percent: 4, state: .charging), "battery.100percent.bolt")
        XCTAssertEqual(ControllerBatteryReading.symbol(percent: nil, state: .unknown), "questionmark.circle")
    }
    @MainActor
    func testNestedInputScopesRestoreParentAndAllowOutOfOrderDismissal() {
        let controller = ControllerManager()
        let parent = controller.pushInputHandler { _ in }
        let child = controller.pushInputHandler { _ in }
        XCTAssertEqual(controller.activeInputScopeID, child)
        controller.popInputHandler(parent)
        XCTAssertEqual(controller.activeInputScopeID, child)
        controller.popInputHandler(child)
        XCTAssertNil(controller.activeInputScopeID)
        let next = controller.pushInputHandler { _ in }
        let nested = controller.pushInputHandler { _ in }
        controller.popInputHandler(nested)
        XCTAssertEqual(controller.activeInputScopeID, next)
        controller.popInputHandler(next)
    }

}
