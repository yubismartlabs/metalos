import XCTest
@testable import MetalOS

final class ConsoleBrowserTests: XCTestCase {
    func testApplicationModeTreatsAppAsSelectionAndOtherFoldersAsNavigation() {
        let app = ConsoleBrowserEntry(url: URL(fileURLWithPath: "/tmp/Game.app"), isDirectory: true, isApplication: true, isPackage: true)
        let folder = ConsoleBrowserEntry(url: URL(fileURLWithPath: "/tmp/Games"), isDirectory: true, isApplication: false, isPackage: false)
        XCTAssertTrue(ConsoleBrowser.permits(app, mode: .application, allowedExtensions: []))
        XCTAssertFalse(ConsoleBrowser.permits(app, mode: .directory, allowedExtensions: []))
        XCTAssertTrue(ConsoleBrowser.permits(folder, mode: .application, allowedExtensions: []))
    }
    func testFilesFilterByExtensionWithoutHidingNavigableFolders() {
        let executable = ConsoleBrowserEntry(url: URL(fileURLWithPath: "/tmp/python3"), isDirectory: false, isApplication: false, isPackage: false)
        let keys = ConsoleBrowserEntry(url: URL(fileURLWithPath: "/tmp/prod.keys"), isDirectory: false, isApplication: false, isPackage: false)
        XCTAssertTrue(ConsoleBrowser.permits(executable, mode: .file, allowedExtensions: []))
        XCTAssertTrue(ConsoleBrowser.permits(keys, mode: .file, allowedExtensions: ["keys"]))
        XCTAssertFalse(ConsoleBrowser.permits(executable, mode: .file, allowedExtensions: ["keys"]))
    }
    func testUnreadableFolderProducesActionableEmptyListing() {
        let result = ConsoleBrowser.list(URL(fileURLWithPath: "/tmp/" + UUID().uuidString), showHidden: false, mode: .directory, allowedExtensions: [])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.message)
    }
    func testFolderSearchKeepsMatchingEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Arcade", "Switch Library", "Native"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let result = ConsoleBrowser.list(folder, showHidden: false, mode: .directory, allowedExtensions: [], query: "switch")
        XCTAssertEqual(result.entries.map(\.name), ["Switch Library"])
    }

}
