import XCTest
@testable import MetalOS

final class OverlayApplicationPolicyTests: XCTestCase {
    func testStorefrontPayloadMatchesItsGameButNotNeighboringFolder() {
        let root = "/Volumes/External Games/Steam/steamapps/common/Example"
        XCTAssertTrue(OverlayApplicationPolicy.matches(installPath: root, bundleURL: URL(fileURLWithPath: root + "/Example.app"), executableURL: nil, bundleIdentifier: "com.example.game"))
        XCTAssertTrue(OverlayApplicationPolicy.matches(installPath: root, bundleURL: nil, executableURL: URL(fileURLWithPath: root + "/bin/game"), bundleIdentifier: nil))
        XCTAssertFalse(OverlayApplicationPolicy.matches(installPath: root, bundleURL: URL(fileURLWithPath: root + " Other/Game.app"), executableURL: nil, bundleIdentifier: "com.other.game"))
    }
    func testClientIsExcludedEvenIfItsPathLooksLikeThePayload() {
        for identifier in ["com.valvesoftware.steam", "com.heroicgameslauncher.hgl", "com.codeweavers.CrossOver", "com.varyform.nxplay"] {
            XCTAssertFalse(OverlayApplicationPolicy.matches(installPath: "/Games", bundleURL: URL(fileURLWithPath: "/Games/Client.app"), executableURL: nil, bundleIdentifier: identifier))
        }
    }
    func testQuitIsOnlyOfferedForDirectNativeApps() {
        for source in [GameSource.native, .appStore, .nxnative] { XCTAssertTrue(OverlayApplicationPolicy.permitsQuit(source: source)) }
        for source in [GameSource.steam, .heroic, .crossover, .all] { XCTAssertFalse(OverlayApplicationPolicy.permitsQuit(source: source)) }
    }
    func testUnrelatedWineHostCannotBecomeTrackedGame() {
        XCTAssertFalse(OverlayApplicationPolicy.matches(installPath: "/Volumes/External Games/Heroic/Example", bundleURL: URL(fileURLWithPath: "/Applications/CrossOver.app"), executableURL: URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/wine/bin/wine64"), bundleIdentifier: "com.codeweavers.wine"))
        XCTAssertFalse(OverlayApplicationPolicy.matches(installPath: "/", bundleURL: URL(fileURLWithPath: "/Applications/Game.app"), executableURL: nil, bundleIdentifier: nil))
    }
}
