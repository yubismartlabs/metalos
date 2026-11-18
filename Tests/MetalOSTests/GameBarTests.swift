import XCTest
@testable import MetalOS

final class GameBarTests: XCTestCase {
    func testDurationShowsMinutesThenHours() {
        XCTAssertEqual(GameBarFormatting.duration(0), "00:00")
        XCTAssertEqual(GameBarFormatting.duration(65), "01:05")
        XCTAssertEqual(GameBarFormatting.duration(3 * 3600 + 7 * 60 + 9), "3:07:09")
        XCTAssertEqual(GameBarFormatting.duration(nil), "—")
    }

    func testCPUAndMemoryPlaceholders() {
        XCTAssertEqual(GameBarFormatting.cpu(nil), "—")
        XCTAssertEqual(GameBarFormatting.cpu(12.4), "12%")
        XCTAssertEqual(GameBarFormatting.memory(nil), "—")
        XCTAssertEqual(GameBarFormatting.memory(0), "—")
        XCTAssertTrue(GameBarFormatting.memory(512 * 1024).contains("512"))
    }

    func testSamplerReadsTheCurrentProcess() {
        var sampler = GameProcessSampler()
        let first = sampler.sample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first?.memoryBytes ?? 0, 0)
        let second = sampler.sample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(second)
        XCTAssertGreaterThanOrEqual(second?.cpuPercent ?? -1, 0)
    }

    func testSamplerRejectsMissingProcess() {
        var sampler = GameProcessSampler()
        XCTAssertNil(sampler.sample(pid: 999_999))
    }
}
