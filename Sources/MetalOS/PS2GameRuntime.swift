import AppKit
import Combine
import CryptoKit
import Foundation

struct PS2Release: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let digest: String?
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let htmlURL: URL
    let prerelease: Bool
    let body: String?
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case prerelease, assets
        case body
    }
}

enum PS2RuntimeLayout {
    static func root(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".nxstudio/Engines/ARMSX2", isDirectory: true)
    }

    static func installDirectory(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("Runtime", isDirectory: true)
    }

    static func versionFile(in workspace: URL) -> URL {
        root(in: workspace).appendingPathComponent("version.txt")
    }

    static func application(in workspace: URL) -> URL? {
        findApplication(in: installDirectory(in: workspace))
    }

    static func executable(in application: URL) -> URL? {
        guard let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String,
              !name.isEmpty else { return nil }
        let executable = application.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    static func findApplication(in directory: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }
        for case let candidate as URL in enumerator where candidate.pathExtension.lowercased() == "app" {
            guard let executable = executable(in: candidate) else { continue }
            let name = candidate.lastPathComponent.lowercased()
            let executableName = executable.lastPathComponent.lowercased()
            if name.contains("pcsx2") || name.contains("armsx2") || executableName.contains("pcsx2") || executableName.contains("armsx2") {
                return candidate
            }
        }
        return nil
    }
}

@MainActor
final class PS2RuntimeManager: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var installedVersion: String?
    @Published private(set) var status = "ARMSX2 is not installed."
    @Published private(set) var applicationURL: URL?

    func latestRelease() async throws -> PS2Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ARMSX2/ARMSX2/releases?per_page=20")!)
        request.timeoutInterval = 25
        request.setValue("MetalOS PS2 runtime installer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StudioError.message("GitHub did not return ARMSX2 release information.")
        }
        let releases = try JSONDecoder().decode([PS2Release].self, from: data)
        guard let release = releases.first(where: { release in
            release.tagName.hasPrefix("nightly-") && release.prerelease
                && release.assets.contains { $0.name == "macOS-arm64.tar.xz" && $0.size > 0 && $0.size < 1_500_000_000 }
        }) else {
            throw StudioError.message("ARMSX2 has no supported macOS arm64 nightly in the latest releases.")
        }
        return release
    }

    func refresh(workspace: URL?) {
        guard let workspace else {
            applicationURL = nil
            installedVersion = nil
            status = "Choose a library folder before installing ARMSX2."
            return
        }
        applicationURL = PS2RuntimeLayout.application(in: workspace)
        guard applicationURL != nil else {
            installedVersion = nil
            status = "ARMSX2 is not installed in this library folder."
            return
        }
        let marker = (try? String(contentsOf: PS2RuntimeLayout.versionFile(in: workspace), encoding: .utf8)) ?? ""
        installedVersion = marker.components(separatedBy: .newlines).first.flatMap { $0.isEmpty ? nil : $0 } ?? "Installed"
        status = "ARMSX2 \(installedVersion ?? "") is installed in this library folder."
    }

    func install(workspace: URL?, checkedRelease: PS2Release? = nil) async {
        guard !isWorking else { return }
        guard let workspace else { status = "Choose a library folder first."; return }
        #if !arch(arm64)
        status = "The managed ARMSX2 runtime requires an Apple Silicon Mac."
        return
        #else
        isWorking = true
        defer { isWorking = false }

        let root = PS2RuntimeLayout.root(in: workspace)
        let destination = PS2RuntimeLayout.installDirectory(in: workspace)
        let archive = root.appendingPathComponent("ARMSX2-macOS-arm64.tar.xz")
        let staging = root.appendingPathComponent(".runtime-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            status = "Checking the latest ARMSX2 Apple Silicon build…"
            let release: PS2Release
            if let checkedRelease { release = checkedRelease }
            else { release = try await latestRelease() }
            guard let asset = release.assets.first(where: { $0.name == "macOS-arm64.tar.xz" && $0.size > 0 && $0.size < 1_500_000_000 }) else {
                throw StudioError.message("ARMSX2 has no supported macOS arm64 nightly in the latest releases.")
            }
            if installedVersion == release.tagName, applicationURL != nil {
                status = "ARMSX2 \(release.tagName) is already up to date."
                return
            }

            status = "Downloading ARMSX2 \(release.tagName)…"
            var downloadRequest = URLRequest(url: asset.browserDownloadURL)
            downloadRequest.setValue("MetalOS PS2 runtime installer", forHTTPHeaderField: "User-Agent")
            let (temporary, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw StudioError.message("The ARMSX2 archive could not be downloaded.")
            }
            try FileManager.default.moveItem(at: temporary, to: archive)
            if let digest = asset.digest, digest.hasPrefix("sha256:") {
                let actual = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
                guard actual == String(digest.dropFirst("sha256:".count)).lowercased() else {
                    throw StudioError.message("The downloaded ARMSX2 archive failed its SHA-256 check.")
                }
            }

            status = "Checking the ARMSX2 archive…"
            let listing = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
            let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard !entries.isEmpty, entries.count < 500_000,
                  entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                throw StudioError.message("The ARMSX2 archive contains an invalid file path.")
            }

            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            status = "Extracting ARMSX2 \(release.tagName)…"
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
            guard let application = PS2RuntimeLayout.findApplication(in: staging),
                  let executable = PS2RuntimeLayout.executable(in: application),
                  try await Self.isArm64(executable) else {
                throw StudioError.message("The ARMSX2 nightly did not contain a runnable Apple Silicon app.")
            }

            var backup: URL?
            if FileManager.default.fileExists(atPath: destination.path) {
                let backupURL = root.appendingPathComponent(".runtime-backup-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: destination, to: backupURL)
                backup = backupURL
            }
            var movedReplacement = false
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                movedReplacement = true
                try "\(release.tagName)\n\(release.htmlURL.absoluteString)\n".write(
                    to: PS2RuntimeLayout.versionFile(in: workspace), atomically: true, encoding: .utf8
                )
            } catch {
                if movedReplacement { try? FileManager.default.removeItem(at: destination) }
                if let backup, !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.moveItem(at: backup, to: destination)
                }
                throw error
            }
            if let backup { try? FileManager.default.removeItem(at: backup) }
            try? FileManager.default.removeItem(at: archive)
            refresh(workspace: workspace)
            status = "ARMSX2 \(release.tagName) is ready. Its first launch may require approval in macOS Privacy & Security."
        } catch {
            status = "ARMSX2 installation failed: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }
        #endif
    }

    func openSetup(workspace: URL?) {
        guard let workspace, let applicationURL = PS2RuntimeLayout.application(in: workspace) else {
            status = "Install ARMSX2 before opening its setup."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if error != nil {
                    self?.status = "ARMSX2 could not be opened. If macOS blocked the unsigned nightly, approve it in Privacy & Security and try again."
                } else {
                    self?.status = "ARMSX2 is open. Set up a PS2 BIOS dumped from your own console."
                }
            }
        }
    }

    private nonisolated static func isArm64(_ executable: URL) async throws -> Bool {
        let output = try await run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", executable.path])
        return output.split(whereSeparator: \.isWhitespace).contains("arm64")
    }

    private nonisolated static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw StudioError.message(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(executable.lastPathComponent) failed." : text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return text
        }.value
    }
}
