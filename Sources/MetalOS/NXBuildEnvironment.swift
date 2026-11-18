import Foundation

/// Finds a usable local toolchain so adding a game does not become a setup exercise.
enum NXBuildEnvironment {
    static func applyDefaults(to settings: inout LauncherSettings, discoverCheckout shouldDiscoverCheckout: Bool = true) {
        if shouldDiscoverCheckout, !isCheckout(settings.forkPath), let checkout = discoverCheckout() { settings.forkPath = checkout }
        if !isPython(settings.pythonPath), let python = discoverPython() { settings.pythonPath = python }
        if !isKeysFile(settings.keysPath), let keys = discoverKeys() { settings.keysPath = keys }
    }

    static func discoverCheckout() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("NativePort/nxnative"),
            home.appendingPathComponent("Library/Application Support/NX Play/nxnative"),
            home.appendingPathComponent("NX2Apple/engine"),
            home.appendingPathComponent("Documents/NXNative"),
            home.appendingPathComponent("Developer/nxnative"),
            home.appendingPathComponent("Projects/nxnative"),
            home.appendingPathComponent("Documents/ChatGPT/NXNative")
        ]
        return candidates.first(where: { isCheckout($0.path) })?.path
    }

    static func discoverKeys() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Ryujinx/system/prod.keys"),
            home.appendingPathComponent("Library/Application Support/yuzu/keys/prod.keys"),
            home.appendingPathComponent("Library/Application Support/suyu/keys/prod.keys"),
            home.appendingPathComponent("Library/Application Support/NSMac/keys/prod.keys"),
            home.appendingPathComponent(".switch/prod.keys")
        ]
        return candidates.first(where: { isKeysFile($0.path) })?.path
    }

    static func discoverPython() -> String? {
        let fixed = [
            "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13", "/usr/local/bin/python3.12", "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
        ]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").flatMap { directory in
                ["python3.13", "python3.12", "python3"].map { String(directory) + "/" + $0 }
            }
        return (fixed + pathCandidates).first(where: isPython)
    }

    static func isCheckout(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: URL(fileURLWithPath: expanded).appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
    }

    static func isKeysFile(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return FileManager.default.isReadableFile(atPath: (path as NSString).expandingTildeInPath)
    }

    static func isPython(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expanded) else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: expanded)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let version = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return version >= 3.12
        } catch { return false }
    }
}
