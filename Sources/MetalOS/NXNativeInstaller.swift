import Foundation
import Combine

struct EngineRequirement: Identifiable, Sendable {
    let id: String
    let detail: String
    let ready: Bool
    let canInstall: Bool
}

private struct EngineRequirementReport: Sendable {
    let items: [EngineRequirement]
    let python: String?
    let brew: String?

    var blockers: [EngineRequirement] { items.filter { !$0.ready && !$0.canInstall } }
    var missingInstallable: [EngineRequirement] { items.filter { !$0.ready && $0.canInstall } }
}
private struct NXNativeUpdateCheckResult: Sendable {
    var message: String
    var available: Bool
    var canInstall: Bool
}

@MainActor
final class NXNativeInstaller: ObservableObject {
    @Published private(set) var requirements: [EngineRequirement] = []
    @Published private(set) var status = "NXNative is not installed."
    @Published private(set) var isWorking = false
    @Published private(set) var updateStatus = "Updates have not been checked."
    @Published private(set) var updateAvailable = false
    @Published var confirmUpdate = false
    @Published var confirmRequirements = false
    @Published var showManualHelp = false

    private var pendingWorkspace: URL?
    private var pendingPython: String?
    private var updateCheckoutPath: String?
    private(set) var installedCheckout: String?
    private(set) var installedPython: String?

    func refresh(workspace: URL?, pythonPath: String, checkoutPath: String = "") async {
        guard let workspace else {
            requirements = []
            status = "Complete setup to choose the folder for NXNative and its requirements."
            return
        }
        let report = await Task.detached(priority: .utility) { Self.check(pythonPath: pythonPath, workspace: workspace) }.value
        requirements = report.items
        let selected = URL(fileURLWithPath: (checkoutPath as NSString).expandingTildeInPath)
        let managed = Self.engineDirectory(workspace)
        if NXBuildEnvironment.isCheckout(checkoutPath) {
            status = selected.standardizedFileURL.path == managed.standardizedFileURL.path
                ? "NXNative is installed in your library folder."
                : "Using the selected NXNative checkout."
        } else {
            status = "NXNative will be installed in your library folder."
        }
    }

    func checkForUpdates(checkoutPath: String) async {
        updateAvailable = false
        updateCheckoutPath = nil
        guard NXBuildEnvironment.isCheckout(checkoutPath) else {
            updateStatus = "Choose a valid NXNative checkout before checking for updates."
            return
        }
        updateStatus = "Checking the NXNative remote…"
        let path = (checkoutPath as NSString).expandingTildeInPath
        let result = await Task.detached(priority: .utility) {
            let git = URL(fileURLWithPath: "/usr/bin/git")
            guard Self.capture(git, ["-C", path, "fetch", "--quiet"]) != nil else {
                return NXNativeUpdateCheckResult(message: "Could not reach the checkout’s configured Git remote. Check your connection and remote settings.", available: false, canInstall: false)
            }
            guard let upstream = Self.capture(git, ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty else {
                return NXNativeUpdateCheckResult(message: "This checkout has no upstream branch configured, so MetalOS cannot compare updates.", available: false, canInstall: false)
            }
            guard let behindText = Self.capture(git, ["-C", path, "rev-list", "--count", "HEAD..\(upstream)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), let behind = Int(behindText),
                  let aheadText = Self.capture(git, ["-C", path, "rev-list", "--count", "\(upstream)..HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), let ahead = Int(aheadText) else {
                return NXNativeUpdateCheckResult(message: "Could not compare the local NXNative checkout with its upstream branch.", available: false, canInstall: false)
            }
            if behind == 0 && ahead == 0 { return NXNativeUpdateCheckResult(message: "NXNative is up to date with \(upstream).", available: false, canInstall: false) }
            if behind > 0 && ahead == 0 {
                guard let workingTree = Self.capture(git, ["-C", path, "status", "--porcelain"])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return NXNativeUpdateCheckResult(message: "Could not check for local changes in the NXNative checkout.", available: false, canInstall: false)
                }
                if !workingTree.isEmpty {
                    return NXNativeUpdateCheckResult(message: "NXNative has \(behind) update\(behind == 1 ? "" : "s"), but this checkout has local changes. Commit or stash them before updating.", available: false, canInstall: false)
                }
                return NXNativeUpdateCheckResult(message: "NXNative has \(behind) update\(behind == 1 ? "" : "s") available from \(upstream).", available: true, canInstall: true)
            }
            if behind > 0 { return NXNativeUpdateCheckResult(message: "NXNative and \(upstream) have diverged (\(behind) remote, \(ahead) local commits). Update the checkout manually.", available: false, canInstall: false) }
            return NXNativeUpdateCheckResult(message: "This checkout is \(ahead) commit\(ahead == 1 ? "" : "s") ahead of \(upstream).", available: false, canInstall: false)
        }.value
        updateStatus = result.message
        updateAvailable = result.available
        if result.canInstall {
            updateCheckoutPath = URL(fileURLWithPath: path).standardizedFileURL.path
            confirmUpdate = true
        }
    }

    func installUpdate(checkoutPath: String) async {
        let path = URL(fileURLWithPath: (checkoutPath as NSString).expandingTildeInPath).standardizedFileURL.path
        guard updateAvailable, updateCheckoutPath == path, NXBuildEnvironment.isCheckout(path), !isWorking else {
            updateStatus = "The update is no longer available for this checkout. Check again."
            return
        }
        isWorking = true
        updateStatus = "Installing the NXNative update…"
        defer { isWorking = false }
        do {
            let git = URL(fileURLWithPath: "/usr/bin/git")
            guard let upstream = Self.capture(git, ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty else {
                throw StudioError.message("This checkout no longer has an upstream branch configured.")
            }
            guard let changes = Self.capture(git, ["-C", path, "status", "--porcelain"])?.trimmingCharacters(in: .whitespacesAndNewlines), changes.isEmpty else {
                throw StudioError.message("The checkout has local changes. Commit or stash them, then check again.")
            }
            guard let behindText = Self.capture(git, ["-C", path, "rev-list", "--count", "HEAD..\(upstream)"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let behind = Int(behindText), behind > 0,
                  let aheadText = Self.capture(git, ["-C", path, "rev-list", "--count", "\(upstream)..HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let ahead = Int(aheadText), ahead == 0 else {
                throw StudioError.message("The checkout changed since the update check. Check again before installing.")
            }
            _ = try await Self.run(git, ["-C", path, "merge", "--ff-only", upstream])
            updateAvailable = false
            updateCheckoutPath = nil
            updateStatus = "NXNative was updated successfully."
        } catch {
            updateStatus = "Could not install NXNative update: \(error.localizedDescription)"
        }
    }

    func install(workspace: URL?, pythonPath: String) async {
        guard let workspace else { status = "Choose a library folder in setup first."; return }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        status = "Checking NXNative requirements…"
        let report = await Task.detached(priority: .utility) { Self.check(pythonPath: pythonPath, workspace: workspace) }.value
        requirements = report.items
        if !report.blockers.isEmpty {
            status = "Before installing NXNative: " + report.blockers.map(\.id).joined(separator: ", ") + "."
            showManualHelp = true
            return
        }
        pendingWorkspace = workspace
        pendingPython = report.python
        if !report.missingInstallable.isEmpty {
            status = "NXNative needs a few build tools and Python packages."
            confirmRequirements = true
            return
        }
        await installEngine(at: workspace, pythonPath: report.python)
    }

    func installConfirmedRequirements() async {
        guard let workspace = pendingWorkspace else { return }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await installRequirements(workspace: workspace, brew: Self.findBrew())
            let python = Self.managedPython(in: workspace) ?? pendingPython ?? NXBuildEnvironment.discoverPython()
            guard let python else { throw StudioError.message("Could not find an Apple Silicon Python 3.12 or newer after installing requirements.") }
            let refreshed = await Task.detached(priority: .utility) { Self.check(pythonPath: python, workspace: workspace) }.value
            requirements = refreshed.items
            if !refreshed.blockers.isEmpty || !refreshed.missingInstallable.isEmpty {
                throw StudioError.message("Some requirements are still missing: " + (refreshed.blockers + refreshed.missingInstallable).map(\.id).joined(separator: ", "))
            }
            await installEngine(at: workspace, pythonPath: python)
        } catch {
            status = "Could not install requirements: \(error.localizedDescription)"
        }
    }

    private func installEngine(at workspace: URL, pythonPath: String?) async {
        do {
            let checkout = Self.engineDirectory(workspace)
            try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !NXBuildEnvironment.isCheckout(checkout.path) {
                if FileManager.default.fileExists(atPath: checkout.path) {
                    throw StudioError.message("The NXNative destination already exists and is not a valid checkout. Move it aside, then try again.")
                }
                status = "Downloading NXNative…"
                let git = URL(fileURLWithPath: "/usr/bin/git")
                let temporary = checkout.deletingLastPathComponent().appendingPathComponent("NXNative-install-\(UUID().uuidString)", isDirectory: true)
                do {
                    _ = try await Self.run(git, ["clone", "--depth", "1", "https://github.com/yubismartlabs/nxnative.git", temporary.path])
                    guard NXBuildEnvironment.isCheckout(temporary.path) else { throw StudioError.message("The downloaded folder is missing NXNative's build script.") }
                    try FileManager.default.moveItem(at: temporary, to: checkout)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }
            guard NXBuildEnvironment.isCheckout(checkout.path) else {
                throw StudioError.message("The downloaded folder is missing NXNative's build script.")
            }
            installedCheckout = checkout.path
            if let python = Self.managedPython(in: workspace) ?? pythonPath { installedPython = python }
            status = "NXNative is ready. Add a Switch game folder to build it for Mac."
        } catch {
            status = "NXNative installation failed: \(error.localizedDescription)"
        }
    }

    private func installRequirements(workspace: URL, brew: String?) async throws {
        guard let brew else { throw StudioError.message("Install Homebrew for Apple Silicon, then retry NXNative setup.") }
        let report = Self.check(pythonPath: pendingPython ?? NXBuildEnvironment.discoverPython() ?? "", workspace: workspace)
        let formulas = ["python@3.13", "xcodegen", "zstd", "glslang"]
        let missingFormulae = formulas.filter { name in
            if name == "python@3.13" { return Self.managedPython(in: workspace) == nil && report.python == nil }
            return !report.items.first(where: { $0.id == name })!.ready
        }
        if !missingFormulae.isEmpty {
            status = "Installing build tools with Homebrew…"
            _ = try await Self.run(URL(fileURLWithPath: brew), ["install"] + missingFormulae)
        }
        let metal = report.items.first(where: { $0.id == "Metal Toolchain" })
        if metal?.ready == false {
            status = "Installing Apple's Metal Toolchain…"
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/xcodebuild"), ["-downloadComponent", "MetalToolchain"])
        }
        guard let python = Self.managedPython(in: workspace) ?? NXBuildEnvironment.discoverPython() else {
            throw StudioError.message("Python 3.13 was not found. Install it with Homebrew and try again.")
        }
        let environment = Self.pythonEnvironment(in: workspace)
        let venvPython = environment.appendingPathComponent("bin/python3")
        if !FileManager.default.isExecutableFile(atPath: venvPython.path) {
            status = "Preparing the app's Python environment…"
            _ = try await Self.run(URL(fileURLWithPath: python), ["-m", "venv", environment.path])
        }
        status = "Installing NXNative's Python packages…"
        _ = try await Self.run(venvPython, ["-m", "pip", "install", "--upgrade", "pip"])
        _ = try await Self.run(venvPython, ["-m", "pip", "install", "lz4", "capstone>=5,<6", "fonttools", "nsz", "zbic", "backports.zstd"])
    }

    nonisolated private static func check(pythonPath: String, workspace: URL? = nil) -> EngineRequirementReport {
        let arm64 = Self.hostArchitecture() == "arm64"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let supportedOS = os.majorVersion > 26 || (os.majorVersion == 26 && os.minorVersion >= 6)
        let brew = findBrew()
        let python = validPython(pythonPath) ?? NXBuildEnvironment.discoverPython().flatMap(validPython)
        let pythonInfo = python.flatMap { capture(URL(fileURLWithPath: $0), ["-c", "import platform,sys; print(f'{sys.version_info.major}.{sys.version_info.minor} {platform.machine()}')"]) }
        let pythonReady = pythonInfo.map { Self.isAtLeast($0, [3, 12]) && $0.localizedCaseInsensitiveContains("arm64") } ?? false
        let xcodeOutput = capture(URL(fileURLWithPath: "/usr/bin/xcodebuild"), ["-version"])
        let xcodeVersion = xcodeOutput?.components(separatedBy: .newlines).first(where: { $0.hasPrefix("Xcode ") })?.replacingOccurrences(of: "Xcode ", with: "") ?? ""
        let xcodeReady = isAtLeast(xcodeVersion, [27, 2])
        let metalReady = capture(URL(fileURLWithPath: "/usr/bin/xcrun"), ["-find", "metal"]) != nil
        let formulaReady: (String) -> Bool = { name in
            guard let brew else { return false }
            return capture(URL(fileURLWithPath: brew), ["list", "--versions", name]) != nil
        }
        let packagePython = workspace.flatMap(managedPython) ?? python
        let pythonPackages = packagePython.flatMap { path in
            capture(URL(fileURLWithPath: path), ["-c", "import sys, lz4.block, capstone, fontTools, nsz, zbic; sys.version_info >= (3,14) or __import__('backports.zstd')"])
        } != nil
        let items = [
            EngineRequirement(id: "Apple Silicon", detail: "NXNative runs on an arm64 Mac.", ready: arm64, canInstall: false),
            EngineRequirement(id: "macOS 26.6 or newer", detail: "Required by the current NXNative build tools.", ready: supportedOS, canInstall: false),
            EngineRequirement(id: "Xcode 27.2 or newer", detail: xcodeVersion.isEmpty ? "Install Xcode from Apple, then select it in Xcode settings." : "Detected \(xcodeVersion).", ready: xcodeReady, canInstall: false),
            EngineRequirement(id: "Metal Toolchain", detail: "Apple's Metal compiler is needed to build game graphics.", ready: metalReady, canInstall: true),
            EngineRequirement(id: "Homebrew", detail: brew == nil ? "Install Homebrew for Apple Silicon to add build tools." : "Detected at \(brew!).", ready: brew != nil, canInstall: false),
            EngineRequirement(id: "Python 3.12+ (arm64)", detail: python == nil ? "MetalOS can install Python 3.13 with Homebrew." : "Detected \(pythonInfo ?? "Python details unavailable").", ready: pythonReady, canInstall: brew != nil),
            EngineRequirement(id: "xcodegen", detail: "Generates the NXNative Mac build project.", ready: formulaReady("xcodegen"), canInstall: brew != nil),
            EngineRequirement(id: "zstd", detail: "Handles compressed Switch game containers.", ready: formulaReady("zstd"), canInstall: brew != nil),
            EngineRequirement(id: "glslang", detail: "Compiles OpenGL game shaders.", ready: formulaReady("glslang"), canInstall: brew != nil),
            EngineRequirement(id: "NXNative Python packages", detail: "Installed in MetalOS's private Python environment.", ready: pythonPackages, canInstall: python != nil || brew != nil)
        ]
        return EngineRequirementReport(items: items, python: python, brew: brew)
    }

    nonisolated private static func engineDirectory(_ workspace: URL) -> URL {
        workspace.appendingPathComponent(".nxstudio/Engines/NXNative-Yubismartlabs", isDirectory: true)
    }
    nonisolated private static func pythonEnvironment(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".nxstudio/Engines/Python", isDirectory: true)
    }
    nonisolated private static func managedPython(in workspace: URL) -> String? {
        let path = pythonEnvironment(in: workspace).appendingPathComponent("bin/python3").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    nonisolated private static func findBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    nonisolated private static func hostArchitecture() -> String {
        capture(URL(fileURLWithPath: "/usr/bin/uname"), ["-m"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    nonisolated private static func validPython(_ path: String) -> String? {
        guard NXBuildEnvironment.isPython(path), let output = capture(URL(fileURLWithPath: path), ["-c", "import platform; print(platform.machine())"]), output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else { return nil }
        return path
    }
    nonisolated private static func version(_ value: String) -> [Int] {
        value.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
    }
    nonisolated private static func isAtLeast(_ value: String, _ minimum: [Int]) -> Bool {
        let actual = version(value)
        for index in 0..<max(actual.count, minimum.count) {
            let left = index < actual.count ? actual[index] : 0
            let right = index < minimum.count ? minimum[index] : 0
            if left != right { return left > right }
        }
        return true
    }
    nonisolated private static func capture(_ executable: URL, _ arguments: [String]) -> String? {
        do {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = commandEnvironment()
            process.standardOutput = output
            process.standardError = output
            try AppProcessSupervisor.run(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }
    nonisolated private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            do {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = commandEnvironment()
                process.standardOutput = output
                process.standardError = output
                try AppProcessSupervisor.run(process)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                guard process.terminationStatus == 0 else { throw StudioError.message(text.isEmpty ? "\(executable.lastPathComponent) exited with status \(process.terminationStatus)." : text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return text
            } catch { throw error }
        }.value
    }
    nonisolated private static func commandEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}
