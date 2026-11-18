import XCTest
@testable import MetalOS

final class NXBuildServiceTests: XCTestCase {
    @MainActor
    func testRealProcessPublishesLogsAndAttributesCompletionToStartedGame() async throws {
        let fixture = try processFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = NXBuildService(buildsRoot: fixture.root.appendingPathComponent("builds"))
        var completedID: String?
        var completedURL: URL?
        service.onComplete = { id, url in completedID = id; completedURL = url }
        service.start(game: fixture.game, settings: fixture.settings)
        try await waitForBuild(service)
        XCTAssertEqual(service.status, "Build complete", service.log)
        XCTAssertEqual(completedID, fixture.game.id)
        XCTAssertEqual(completedURL, service.outputApp)
        XCTAssertTrue(service.log.contains("fixture build finished"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(service.outputApp).appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(service.logFile), encoding: .utf8), service.log)
    }

    @MainActor
    func testFailedRebuildRetainsSuccessfulAppAndAllowsRetry() async throws {
        let fixture = try processFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = NXBuildService(buildsRoot: fixture.root.appendingPathComponent("builds"))
        service.start(game: fixture.game, settings: fixture.settings)
        try await waitForBuild(service)
        let app = try XCTUnwrap(service.outputApp)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let original = try Data(contentsOf: plist)
        try Data().write(to: fixture.root.appendingPathComponent("fail"))
        service.start(game: fixture.game, settings: fixture.settings)
        try await waitForBuild(service)
        XCTAssertTrue(service.status.contains("Build failed"), service.log)
        XCTAssertEqual(try Data(contentsOf: plist), original)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fail"))
        service.start(game: fixture.game, settings: fixture.settings)
        try await waitForBuild(service)
        XCTAssertEqual(service.status, "Build complete", service.log)
    }

    @MainActor
    private func waitForBuild(_ service: NXBuildService) async throws {
        let deadline = Date().addingTimeInterval(15)
        while service.isBuilding && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if service.isBuilding { service.cancel(); XCTFail("Fixture subprocess did not terminate") }
    }

    private func processFixture() throws -> (root: URL, game: Game, settings: LauncherSettings) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import pathlib, sys
        output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
        (output / 'Contents').mkdir(parents=True)
        (output / 'Contents' / 'Info.plist').write_text('fixture app')
        print('fixture build finished', flush=True)
        if pathlib.Path('fail').exists():
            sys.exit(7)
        """
        try script.write(to: scripts.appendingPathComponent("build_ipa_from_nsp.py"), atomically: true, encoding: .utf8)
        var settings = LauncherSettings()
        settings.forkPath = root.path
        settings.pythonPath = "/usr/bin/python3"
        let game = Game(id: "fixture-game", title: "Fixture", source: .nxnative, launchURL: "", installPath: root.path, buildInput: root.path)
        return (root, game, settings)
    }

    func testBuildPlanKeepsUntrustedPathsAsSingleArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fork = root.appendingPathComponent("my fork/scripts")
        try FileManager.default.createDirectory(at: fork, withIntermediateDirectories: true)
        try Data().write(to: fork.appendingPathComponent("build_ipa_from_nsp.py"))
        let input = root.appendingPathComponent("Game $(touch injected); 'space'")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        var settings = LauncherSettings()
        settings.forkPath = fork.deletingLastPathComponent().path
        settings.pythonPath = "/usr/bin/true"
        let game = Game(id: "../../outside", title: "Test", source: .nxnative, launchURL: "", installPath: input.path, buildInput: input.path)
        let plan = try NXBuildPlan.make(game: game, settings: settings, buildsRoot: root.appendingPathComponent("builds"))
        XCTAssertEqual(plan.arguments[1], input.path)
        XCTAssertEqual(plan.workDirectory.path, input.standardizedFileURL.appendingPathComponent(".nxstudio/Work").path)
        let localPlan = try NXBuildPlan.make(game: game, settings: settings)
        XCTAssertEqual(localPlan.outputApp.path, input.standardizedFileURL.appendingPathComponent(".nxstudio/Build/Game.app").path)
        XCTAssertEqual(localPlan.logFile.path, input.standardizedFileURL.appendingPathComponent(".nxstudio/Build/build.log").path)
        XCTAssertEqual(plan.arguments[2...3], ["--platform", "mac-app"])
        XCTAssertTrue(plan.outputApp.path.hasPrefix(root.appendingPathComponent("builds").path + "/"))
        XCTAssertFalse(plan.arguments.contains("-k"))
    }

    func testMissingCheckoutFailsBeforeStartingAProcess() {
        let game = Game(id: "test", title: "Test", source: .nxnative, launchURL: "", installPath: "/tmp", buildInput: "/tmp")
        XCTAssertThrowsError(try NXBuildPlan.make(game: game, settings: LauncherSettings()))
    }

    func testPerTitleForkOverridesGlobalCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data().write(to: scripts.appendingPathComponent("build_ipa_from_nsp.py"))
        var settings = LauncherSettings()
        settings.forkPath = "/not/a/checkout"
        settings.pythonPath = "/usr/bin/true"
        let game = Game(id: "test", title: "Test", source: .nxnative, launchURL: "", installPath: root.path, buildInput: root.path, forkPath: root.path)
        XCTAssertEqual(try NXBuildPlan.make(game: game, settings: settings).workingDirectory, root.standardizedFileURL)
    }
}
