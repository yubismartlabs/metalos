import XCTest
@testable import MetalOS

final class GameDiscoveryTests: XCTestCase {
    func testSteamMultipleLibrariesAndEscapes() {
        let manifest = #""libraryfolders" { "0" { "path" "/Users/player/Steam" } "1" { "path" "/Volumes/Games Drive/SteamLibrary" } }"#
        XCTAssertEqual(GameDiscovery.steamLibraryPaths(manifest), ["/Users/player/Steam", "/Volumes/Games Drive/SteamLibrary"])
    }
    func testSteamLaunchAndTraversalRejection() {
        let manifest = #""AppState" { "appid" "123" "name" "A Game" "installdir" "A Game" }"#
        let game = GameDiscovery.steamGame(manifest: manifest, library: URL(fileURLWithPath: "/Volumes/Disk/Steam"))
        XCTAssertEqual(game?.launchURL, "steam://rungameid/123")
        XCTAssertEqual(game?.installPath, "/Volumes/Disk/Steam/steamapps/common/A Game")
        XCTAssertNil(GameDiscovery.steamGame(manifest: manifest.replacingOccurrences(of: "\"installdir\" \"A Game\"", with: "\"installdir\" \"../outside\""), library: URL(fileURLWithPath: "/tmp")))
    }
    func testHeroicVariantsEncodeAppNameAndIgnoreMissingPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json: [String: Any] = ["installed": [["appName": "Game & More", "title": "Test", "install_path": directory.path], ["appName": "Missing", "install_path": directory.appendingPathComponent("missing").path]]]
        let games = GameDiscovery.heroicInstalled(json, runner: "gog")
        XCTAssertEqual(games.count, 1)
        let components = URLComponents(string: try XCTUnwrap(games.first?.launchURL))
        XCTAssertEqual(components?.queryItems?.first?.value, "Game & More")
        XCTAssertEqual(components?.queryItems?.last?.value, "gog")
    }
    func testDefaultAppDiscoveryRequiresGameCategory() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: [String: Any] = ["CFBundleName": "Utility", "CFBundleIdentifier": "com.test.utility"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(GameDiscovery.appGame(at: app, allowUncategorized: false))
        XCTAssertEqual(GameDiscovery.appGame(at: app, allowUncategorized: true)?.title, "Utility")
    }
    func testBuilderAppsAreNotMistakenForNXNativeGames() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        for bundleID in ["org.nxnative.NSPortBuilder", "com.varyform.nxplay", "org.nxnative.0100f2200c984000"] {
            let plist = ["CFBundleName": "Test", "CFBundleIdentifier": bundleID, "LSApplicationCategoryType": "public.app-category.games"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            if bundleID == "org.nxnative.0100f2200c984000" {
                XCTAssertEqual(GameDiscovery.appGame(at: app, allowUncategorized: false)?.source, .nxnative)
            } else { XCTAssertNil(GameDiscovery.appGame(at: app, allowUncategorized: false)) }
        }
    }

}
