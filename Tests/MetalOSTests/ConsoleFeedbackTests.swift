import XCTest
import AppKit
@testable import MetalOS

final class ConsoleFeedbackTests: XCTestCase {
    func testGeneratedSoundsHaveValidPCMHeadersAndQuietBoundedSamples() {
        for cue in NavigationCue.allCases {
            let data = NavigationTone.wave(cue)
            XCTAssertNotNil(NSSound(data: data))
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
            XCTAssertGreaterThan(data.count, 44)
            XCTAssertEqual((data.count - 44) % 2, 0)
            let samples = stride(from: 44, to: data.count, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
            XCTAssertEqual(samples.first, 0)
            XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, 10_000)
            XCTAssertLessThan(data.count, NavigationTone.sampleRate * 2)
        }
    }
    @MainActor
    func testSoundAndMotionPreferencesPersistWithBoundedVolume() throws {
        let name = "MetalOS-feedback-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ConsoleFeedback(defaults: defaults)
        preferences.soundsEnabled = false
        preferences.reduceMotion = true
        preferences.adjustVolume(100)
        XCTAssertEqual(preferences.volume, 1)
        preferences.adjustVolume(-100)
        XCTAssertEqual(preferences.volume, 0)
        let restored = ConsoleFeedback(defaults: defaults)
        XCTAssertFalse(restored.soundsEnabled)
        XCTAssertTrue(restored.reduceMotion)
        XCTAssertEqual(restored.volume, 0)
    }
    func testUnrecognizedInputDoesNotProduceAudio() {
        XCTAssertNil(NavigationCue.command("gameplay"))
        XCTAssertEqual(NavigationCue.command("left"), .move)
        XCTAssertEqual(NavigationCue.command("confirm"), .confirm)
        XCTAssertEqual(NavigationCue.command("back"), .back)
    }
}
