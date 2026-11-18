import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MetalOS

final class ArtworkCacheTests: XCTestCase {
    func testArtworkDownloadsAcceptOnlyIGDBHTTPS() {
        XCTAssertTrue(ArtworkCache.isTrustedImageURL(URL(string: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/cover.jpg")!))
        for raw in ["http://images.igdb.com/igdb/image/upload/t_cover_big_2x/cover.jpg", "https://images.igdb.com.evil.example/x", "https://steamgriddb.com/x", "file:///tmp/game.png", "https://user:secret@images.igdb.com/x", "https://images.igdb.com:8080/x"] {
            XCTAssertFalse(ArtworkCache.isTrustedImageURL(URL(string: raw)!))
        }
    }
    func testRemovingGameDeletesOnlyThatGamesArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent(ArtworkCache.folderName(for: "kept"), isDirectory: true)
        let removed = root.appendingPathComponent(ArtworkCache.folderName(for: "removed"), isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: kept.appendingPathComponent("cover.jpg"))
        try Data("cover".utf8).write(to: removed.appendingPathComponent("cover.jpg"))
        let cache = ArtworkCache(root: root)
        await cache.removeArtwork(for: "removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("cover.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    }
    func testPruneKeepsOnlyLibraryArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent(ArtworkCache.folderName(for: "kept"), isDirectory: true)
        let orphan = root.appendingPathComponent(ArtworkCache.folderName(for: "orphan"), isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: kept.appendingPathComponent("cover.jpg"))
        let stray = root.appendingPathComponent("stray.jpg")
        try Data("stray".utf8).write(to: stray)
        let cache = ArtworkCache(root: root)
        await cache.prune(keeping: ["kept"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("cover.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }
    func testRetainArtworkDeletesSupersededFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(ArtworkCache.folderName(for: "kept"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = folder.appendingPathComponent("cover-current.jpg")
        let superseded = folder.appendingPathComponent("cover-old.jpg")
        try Data("current".utf8).write(to: current)
        try Data("old".utf8).write(to: superseded)
        let cache = ArtworkCache(root: root)
        await cache.retainArtwork(for: "kept", paths: [current.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: superseded.path))
    }
    func testLegacySteamGridDBCredentialsDecodeWithoutFailing() throws {
        let old = Data(#"{"steamGridDBKey":"old-key"}"#.utf8)
        let credentials = try JSONDecoder().decode(ArtworkCredentials.self, from: old)
        XCTAssertEqual(credentials.igdbClientID, "")
        XCTAssertEqual(credentials.igdbClientSecret, "")
        XCTAssertFalse(credentials.isConfigured)
    }
    func testIGDBCredentialsRoundTrip() throws {
        let credentials = ArtworkCredentials(igdbClientID: "client", igdbClientSecret: "secret")
        let decoded = try JSONDecoder().decode(ArtworkCredentials.self, from: JSONEncoder().encode(credentials))
        XCTAssertEqual(decoded, credentials)
        XCTAssertTrue(decoded.isConfigured)
    }
    func testInvalidDownloadDoesNotEnterCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try Data("<html>Service unavailable</html>".utf8).write(to: source)
        let target = root.appendingPathComponent("cover.jpg")
        XCTAssertThrowsError(try ArtworkCache.storeImage(input: source, target: target, kind: .cover))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testCoverImagesAreDownsizedAndRemainDecodable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.png"), target = root.appendingPathComponent("cache/cover.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 1800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        try ArtworkCache.storeImage(input: source, target: target, kind: .cover)
        let cached = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(cached, 0, nil))
        XCTAssertEqual(image.height, 1000)
        XCTAssertEqual(Double(image.width) / Double(image.height), 2.0 / 3.0, accuracy: 0.002)
    }
    func testExistingLibrariesDecodeWithoutArtworkFields() throws {
        let old = Data(#"{"games":[{"id":"old","title":"Game","source":"Native","launchURL":"","installPath":"/tmp","favorite":false}],"settings":{"forkPath":"","pythonPath":"/usr/bin/python3","keysPath":"","scanRoots":[],"startInConsole":false}}"#.utf8)
        let library = try JSONDecoder().decode(LibraryData.self, from: old)
        XCTAssertNil(library.games.first?.boxArt)
        XCTAssertNil(library.games.first?.heroArt)
        XCTAssertNil(library.games.first?.artworkCheckedAt)
        XCTAssertNil(library.settings.automaticallyFetchArtwork)
    }
}
