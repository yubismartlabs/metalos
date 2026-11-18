import XCTest
@testable import MetalOS

final class SwitchGameDiscoveryTests: XCTestCase {
    private func fixture(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testDetectsOneGamePerFolderWithBaseUpdateAndDLC() throws {
        let root = try fixture([
            "my-game/Super Mario Bros. Wonder [010015100B514000][v0].nsp",
            "my-game/Update [010015100B514800].nsz",
            "my-game/DLC [010015100B515001].nsp",
            "Other/Other [0100A6301214E000].xci",
            "my-game/.nxstudio/Work/extracted [0100999999990000].nsp",
            "my-game/.nxstudio/Build/Game.app/Contents/Info.plist"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = SwitchGameDiscovery.scan(root: root)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.games.count, 2)
        let wonder = try XCTUnwrap(result.games.first { $0.titleID == "010015100B514000" })
        XCTAssertEqual(wonder.title, "my-game")
        XCTAssertEqual(wonder.buildInput, root.appendingPathComponent("my-game").path)
        XCTAssertEqual(wonder.installPath, wonder.buildInput)
        XCTAssertEqual(SwitchGameDiscovery.scan(root: root.appendingPathComponent("my-game")).games.first?.id, wonder.id)
    }

    func testFolderNameIsPreservedExactlyAndContentLikeNamesAreGames() throws {
        let names = ["my-game", "Game", "BaseGame", "Update", "DLC", "My Game [USA] v2.nsp"]
        let root = try fixture(names.map { "\($0)/Unrelated container name [010015100B514000].NSZ" })
        defer { try? FileManager.default.removeItem(at: root) }
        let games = SwitchGameDiscovery.scan(root: root).games
        XCTAssertEqual(Set(games.map(\.title)), Set(names))
        for game in games { XCTAssertEqual(game.buildInput, root.appendingPathComponent(game.title).path) }
    }

    func testRejectsMixedGamesAndUpdateOnlyFoldersButKeepsUnidentifiedGame() throws {
        let root = try fixture([
            "Mixed/Game [010015100B514000].nsp", "Mixed/Other [0100A6301214E000].nsp",
            "UpdateOnly/Update [010015100B514800].nsp", "Unknown/basegame.xcz"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = SwitchGameDiscovery.scan(root: root)
        XCTAssertEqual(result.games.map(\.title), ["Unknown"])
        XCTAssertNil(result.games.first?.titleID)
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testSkipsSymlinkAndAppContents() throws {
        let root = try fixture(["Actual/Game [010015100B514000].nsp", "Tool.app/Contents/Fake.nsp"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: root.appendingPathComponent("Actual"))
        XCTAssertEqual(SwitchGameDiscovery.scan(root: root).games.count, 1)
    }

    func testOfficialCatalogMatchesExactTitleIDAndDoesNotInferSupportFromNames() throws {
        let catalog = try NXSupportCatalog(markdown: """
        Each game has a folder, such as `0100A6301214E000`.
        | Game | Title ID | Build | SDK | Engine | Graphics |
        |---|---|---|---|---|---|
        | [Super Mario Bros. Wonder](010015100B514000/README.md) | `010015100B514000` | 1.0.1 | 16 | Custom | NVN |
        """)
        XCTAssertEqual(catalog.status(titleID: "010015100b514000").state, .listed)
        XCTAssertTrue(catalog.status(titleID: "010015100B514000").note.contains("1.0.1"))
        XCTAssertEqual(catalog.status(titleID: "0100A6301214E000").state, .unlisted)
        XCTAssertEqual(catalog.status(titleID: nil).state, .unknown)
        XCTAssertThrowsError(try NXSupportCatalog(markdown: "Unavailable"))
    }

    @MainActor
    func testExistingImportUsesFolderTitleOnReloadEvenWhenOffline() throws {
        let root = try fixture(["placeholder"])
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("library.json")
        var data = LibraryData()
        data.games = [Game(id: "existing", title: "Container filename", source: .nxnative,
                           launchURL: "file:///built/Game.app", installPath: "/built/Game.app",
                           favorite: true, buildInput: "/Volumes/Offline/Library/my-game")]
        try JSONEncoder().encode(data).write(to: storage)
        let store = LibraryStore(storage: storage)
        XCTAssertEqual(store.data.games[0].title, "my-game")
        XCTAssertEqual(store.data.games[0].launchURL, "file:///built/Game.app")
        XCTAssertTrue(store.data.games[0].favorite)
    }

    @MainActor
    func testRescanPreservesBuiltAppFavoritesAndForkWithoutDuplicateEntries() throws {
        let root = try fixture(["Wonder/Game [010015100B514000].nsp"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(storage: root.appendingPathComponent("library.json"), artworkCache: ArtworkCache(root: root.appendingPathComponent("Artwork")))
        let detected = SwitchGameDiscovery.scan(root: root).games
        store.mergeDiscoveredGames(detected)
        store.data.games[0].id = "legacy-import-id"
        store.data.games[0].launchURL = "file:///built/Game.app"
        store.data.games[0].installPath = "/built/Game.app"
        store.data.games[0].favorite = true
        store.data.games[0].forkPath = "/my/fork"
        store.data.games[0].title = "Old filename-derived title"
        store.mergeDiscoveredGames(detected)
        XCTAssertEqual(store.data.games[0].title, "Wonder")
        XCTAssertEqual(store.data.games.count, 1)
        XCTAssertEqual(store.data.games[0].launchURL, "file:///built/Game.app")
        XCTAssertEqual(store.data.games[0].installPath, "/built/Game.app")
        XCTAssertEqual(store.data.games[0].forkPath, "/my/fork")
        XCTAssertTrue(store.data.games[0].favorite)
        store.save()
        let reloaded = LibraryStore(storage: root.appendingPathComponent("library.json"))
        XCTAssertEqual(reloaded.data.games[0].titleID, "010015100B514000")
    }
}
