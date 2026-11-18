import XCTest
@testable import MetalOS

final class LibraryStoreTests: XCTestCase {
    @MainActor
    func testMetadataAndPerTitleCheckoutSurviveReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.json")
        let store = LibraryStore(storage: path)
        store.data.games = [Game(id: "switch-test", title: "Test Title", source: .nxnative, launchURL: "", installPath: "/Volumes/Offline/Input", favorite: true, buildInput: "/Volumes/Offline/Input", forkPath: "/forks/title-fix")]
        store.data.settings.forkPath = "/forks/default"
        store.save()
        let reloaded = LibraryStore(storage: path)
        XCTAssertEqual(reloaded.data.games.first?.forkPath, "/forks/title-fix")
        XCTAssertEqual(reloaded.data.settings.forkPath, "/forks/default")
        XCTAssertEqual(reloaded.data.games.first?.favorite, true)
        XCTAssertEqual(reloaded.data.games.first?.isAvailable, false)
    }
    @MainActor
    func testRemovingGameDeletesItsStoredArtwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artworkRoot = folder.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let game = Game(id: "game-to-remove", title: "Game", source: .native, launchURL: "", installPath: "/tmp")
        var library = LibraryData()
        library.games = [game]
        try JSONEncoder().encode(library).write(to: folder.appendingPathComponent("library.json"))
        let store = LibraryStore(storage: folder.appendingPathComponent("library.json"), artworkCache: ArtworkCache(root: artworkRoot))
        let gameArtwork = artworkRoot.appendingPathComponent(ArtworkCache.folderName(for: game.id), isDirectory: true)
        try FileManager.default.createDirectory(at: gameArtwork, withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: gameArtwork.appendingPathComponent("cover.jpg"))
        store.removeGame(id: game.id)
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: gameArtwork.path) { break }
            await Task.yield()
        }
        XCTAssertTrue(store.data.games.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameArtwork.path))
    }
    @MainActor
    func testUnreadableLibraryBackedUpBeforeSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.json")
        let original = Data("broken library".utf8)
        try original.write(to: path)
        let store = LibraryStore(storage: path)
        store.save()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("unreadable-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertNoThrow(try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: path)))
    }
    @MainActor
    func testControllerImportAddsAnAppWithoutDuplicatingItsMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = folder.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist = ["CFBundleName": "Controller Fixture", "CFBundleIdentifier": "test.controller.fixture", "LSApplicationCategoryType": "public.app-category.games"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let store = LibraryStore(storage: folder.appendingPathComponent("library.json"), artworkCache: ArtworkCache(root: folder.appendingPathComponent("Artwork")))
        store.importApp()
        XCTAssertTrue(store.showGameImport)
        XCTAssertTrue(store.addMacApp(at: app))
        store.data.games[0].favorite = true
        XCTAssertTrue(store.addMacApp(at: app))
        XCTAssertEqual(store.data.games.count, 1)
        XCTAssertTrue(store.data.games[0].favorite)
        XCTAssertEqual(store.data.games[0].title, "Controller Fixture")
    }
    @MainActor
    func testFullScreenPreferenceDefaultsOnForOlderLibrariesAndPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.json")
        let legacy = #"{"games":[],"settings":{"forkPath":"/fork","pythonPath":"/usr/bin/python3","keysPath":"","scanRoots":[],"startInConsole":false}}"#
        try Data(legacy.utf8).write(to: path)
        let store = LibraryStore(storage: path)
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.data.settings.forkPath, "/fork")
        XCTAssertNotEqual(store.data.settings.startGamesFullScreen, false)
        store.data.settings.startGamesFullScreen = false
        store.save()
        XCTAssertEqual(LibraryStore(storage: path).data.settings.startGamesFullScreen, false)
    }

}
