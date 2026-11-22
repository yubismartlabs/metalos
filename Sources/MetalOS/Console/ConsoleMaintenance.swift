import AppKit
import Combine
import Foundation
import SwiftUI

enum ConsoleComponent: String, CaseIterable, Identifiable {
    case app = "MetalOS"
    case nxnative = "NXNative"
    case armsx2 = "ARMSX2"
    case legendary = "Legendary"
    case gogdl = "gogdl"
    case wine = "Windows Runtime"
    case toolkit = "Game Porting Toolkit"
    case native = "Native macOS"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .app, .native: "apple.logo"
        case .nxnative: "gamecontroller"
        case .armsx2: "opticaldisc"
        case .legendary: "e.square"
        case .gogdl: "g.square"
        case .wine: "pc"
        case .toolkit: "cpu"
        }
    }

    static let managed: [Self] = [.nxnative, .armsx2, .wine, .toolkit, .legendary, .gogdl]
}

struct ConsoleUpdateNote {
    let title: String
    let body: String
    var url: URL?
}

private struct ConsoleAppRelease: Decodable {
    let tag: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let url: URL

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", url = "html_url"
        case draft, prerelease, body
    }

    func matches(_ channel: ConsoleUpdateChannel) -> Bool {
        guard !draft else { return false }
        let nightly = tag.localizedCaseInsensitiveContains("nightly")
        switch channel {
        case .stable: return !prerelease && !nightly
        case .beta: return prerelease && !nightly
        case .nightly: return nightly
        }
    }
}

@MainActor
final class ConsoleMaintenance: ObservableObject {
    enum Operation { case check, install, all }

    @Published private(set) var component: ConsoleComponent?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var reports: [ConsoleComponent: String] = [:]
    @Published private(set) var notes: [ConsoleComponent: ConsoleUpdateNote] = [:]
    @Published private(set) var updates: Set<ConsoleComponent> = []
    @Published private(set) var versions: [ConsoleComponent: String] = [:]
    @Published var requirementsConfirmation = false
    @Published var requirementsHelp = false

    private let nx = NXNativeInstaller()
    private let ps2 = PS2RuntimeManager()
    private let storefronts = WindowsStorefrontRuntime()
    private let wine = WindowsWineInstaller()
    private let toolkit = GamePortingToolkitInstaller()
    private var observations: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var inventoryID = UUID()

    init() {
        for publisher in [nx.objectWillChange, ps2.objectWillChange, storefronts.objectWillChange,
                          wine.objectWillChange, toolkit.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
    }

    var isWorking: Bool { task != nil || component != nil }
    var progress: Double? {
        if component == .wine, let progress = wine.progress {
            return (Double(completed) + progress) / Double(max(total, 1))
        }
        return total > 1 ? Double(completed) / Double(total) : nil
    }
    var liveStatus: String? {
        switch component {
        case .nxnative: nx.isWorking ? nx.status : nx.updateStatus
        case .armsx2: ps2.status
        case .legendary, .gogdl: storefronts.status
        case .wine: wine.status
        case .toolkit: toolkit.status
        case .app: "Checking the MetalOS release feed…"
        default: nil
        }
    }
    var requirements: [EngineRequirement] { nx.requirements }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    func checkout(for store: LibraryStore) -> String? {
        let configured = store.data.settings.forkPath
        if NXBuildEnvironment.isCheckout(configured) { return configured }
        guard let path = store.workspaceURL?.appendingPathComponent(".nxstudio/Engines/NXNative-Yubismartlabs").path,
              NXBuildEnvironment.isCheckout(path) else { return nil }
        return path
    }

    func installed(_ item: ConsoleComponent, in store: LibraryStore) -> Bool {
        if item == .app || item == .native { return true }
        if item == .nxnative { return checkout(for: store) != nil }
        guard let workspace = store.workspaceURL else { return false }
        switch item {
        case .armsx2: return PS2RuntimeLayout.application(in: workspace) != nil
        case .legendary: return FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.legendaryCLI(in: workspace).path)
        case .gogdl: return FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.gogdlCLI(in: workspace).path)
        case .wine: return WindowsRuntimeLayout.wineExecutable(in: workspace) != nil
        case .toolkit: return WindowsRuntimeLayout.gamePortingToolkitWineExecutable(in: workspace) != nil
        default: return false
        }
    }

    func refresh(_ store: LibraryStore) async {
        let id = UUID()
        inventoryID = id
        if !ps2.isWorking { ps2.refresh(workspace: store.workspaceURL) }
        if !wine.isWorking { wine.refresh(workspace: store.workspaceURL) }
        if !toolkit.isWorking { toolkit.refresh(workspace: store.workspaceURL) }
        let path = checkout(for: store)
        let workspace = store.workspaceURL
        let python = store.data.settings.pythonPath
        let armVersion = ps2.installedVersion
        let wineVersion = wine.installedVersion
        let toolkitVersion = toolkit.installedVersion
        let versions = await Task.detached(priority: .utility) {
            var found: [ConsoleComponent: String] = [:]
            if let path { found[.nxnative] = Self.read(URL(fileURLWithPath: "/usr/bin/git"), ["-C", path, "rev-parse", "--short", "HEAD"]) }
            if let workspace {
                found[.armsx2] = armVersion
                let legendary = WindowsRuntimeLayout.legendaryCLI(in: workspace)
                let gog = WindowsRuntimeLayout.gogdlCLI(in: workspace)
                if FileManager.default.isExecutableFile(atPath: legendary.path) { found[.legendary] = Self.read(legendary, ["--version"]) }
                if FileManager.default.isExecutableFile(atPath: gog.path) { found[.gogdl] = Self.read(gog, ["--version"]) }
                found[.wine] = wineVersion
                found[.toolkit] = toolkitVersion
            }
            return found
        }.value
        guard inventoryID == id, !Task.isCancelled else { return }
        self.versions = versions
        if !isWorking { await nx.refresh(workspace: workspace, pythonPath: python, checkoutPath: path ?? "") }
    }

    func openPS2Setup(_ store: LibraryStore) {
        ps2.openSetup(workspace: store.workspaceURL)
    }

    func run(_ operation: Operation, item: ConsoleComponent? = nil, store: LibraryStore, channel: ConsoleUpdateChannel) {
        guard task == nil, !requirementsConfirmation else { return }
        let queue: [ConsoleComponent]
        if operation == .all {
            queue = [.app] + ConsoleComponent.managed.filter {
                guard installed($0, in: store) else { return false }
                if $0 == .toolkit, let workspace = store.workspaceURL {
                    return FileManager.default.isExecutableFile(atPath: WindowsRuntimeLayout.gamePortingToolkitWine(in: workspace).path)
                }
                return true
            }
        } else {
            guard let item else { return }
            queue = [item]
        }
        let modifiesRuntimes = operation != .check && queue.contains { $0 != .app }
        if modifiesRuntimes, !store.beginRuntimeMaintenance() { return }
        total = queue.count
        completed = 0
        if operation == .all { reports.removeAll() }
        task = Task { @MainActor in
            defer {
                if modifiesRuntimes { store.endRuntimeMaintenance() }
                component = nil
                task = nil
                requirementsConfirmation = nx.confirmRequirements
                requirementsHelp = nx.showManualHelp
                nx.confirmRequirements = false
                nx.showManualHelp = false
            }
            for entry in queue {
                component = entry
                switch entry {
                case .app: await checkApp(channel)
                case .nxnative: await runNX(operation, store)
                case .armsx2: await runPS2(operation, store)
                case .legendary: await runLegendary(operation, store)
                case .gogdl: await runGOG(operation, store)
                case .wine:
                    if operation != .check { await wine.install(workspace: store.workspaceURL) }
                    reports[.wine] = wine.status
                case .toolkit:
                    if operation != .check { await toolkit.install(workspace: store.workspaceURL) }
                    reports[.toolkit] = toolkit.status
                default: break
                }
                completed += 1
            }
            await refresh(store)
        }
    }

    func confirmRequirements(_ store: LibraryStore) {
        guard task == nil, store.beginRuntimeMaintenance() else { return }
        task = Task { @MainActor in
            component = .nxnative
            total = 1
            completed = 0
            defer {
                store.endRuntimeMaintenance()
                component = nil
                task = nil
                completed = 1
            }
            await nx.installConfirmedRequirements()
            persistNX(store)
            reports[.nxnative] = nx.status
            await refresh(store)
        }
    }

    private func checkApp(_ channel: ConsoleUpdateChannel) async {
        let item = ConsoleComponent.app
        notes[item] = nil
        updates.remove(item)
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/yubismartlabs/metalos/releases?per_page=50")!)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw StudioError.message("The launcher release feed is unavailable.")
            }
            let releases = try JSONDecoder().decode([ConsoleAppRelease].self, from: data)
            guard let release = releases.first(where: { $0.matches(channel) }) else {
                reports[item] = "No \(channel.rawValue.lowercased()) release published."
                return
            }
            notes[item] = ConsoleUpdateNote(title: "MetalOS \(release.tag)",
                                            body: release.body ?? "No changelog published.", url: release.url)
            let installed = Self.appVersion
            let remote = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            let numericVersions = [installed, remote].allSatisfy { $0.allSatisfy { $0.isNumber || $0 == "." } }
            if installed == remote || (numericVersions && remote.compare(installed, options: .numeric) == .orderedAscending) {
                reports[item] = "Installed \(installed) · Latest \(release.tag)"
            } else if numericVersions {
                updates.insert(item)
                reports[item] = "\(release.tag) is available from the release page."
            } else {
                reports[item] = "Latest \(channel.rawValue): \(release.tag). Compare with the installed build."
            }
        } catch {
            reports[item] = error.localizedDescription
        }
    }

    private func runNX(_ operation: Operation, _ store: LibraryStore) async {
        if let checkout = checkout(for: store) {
            if operation != .install || !nx.updateAvailable {
                await nx.checkForUpdates(checkoutPath: checkout)
            }
            if nx.updateAvailable {
                updates.insert(.nxnative)
                let log = await Task.detached(priority: .utility) {
                    Self.read(URL(fileURLWithPath: "/usr/bin/git"),
                              ["-C", checkout, "log", "-12", "--format=%h %s", "HEAD..@{u}"], multiline: true)
                }.value
                if let log { notes[.nxnative] = .init(title: "NXNative upstream changes", body: log) }
                if operation != .check {
                    await nx.installUpdate(checkoutPath: checkout)
                    if !nx.updateAvailable { updates.remove(.nxnative) }
                }
            } else {
                updates.remove(.nxnative)
            }
            reports[.nxnative] = nx.updateStatus
        } else if operation == .install {
            await nx.install(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
            persistNX(store)
            reports[.nxnative] = nx.status
        }
    }

    private func persistNX(_ store: LibraryStore) {
        if let checkout = nx.installedCheckout { store.data.settings.forkPath = checkout }
        if let python = nx.installedPython { store.data.settings.pythonPath = python }
        store.save()
    }

    private func runPS2(_ operation: Operation, _ store: LibraryStore) async {
        ps2.refresh(workspace: store.workspaceURL)
        do {
            let release = try await ps2.latestRelease()
            notes[.armsx2] = .init(title: "ARMSX2 \(release.tagName)", body: release.body ?? "No changelog published.", url: release.htmlURL)
            if ps2.installedVersion == release.tagName {
                reports[.armsx2] = "Up to date · \(release.tagName)"
                updates.remove(.armsx2)
            } else if operation == .check {
                if ps2.applicationURL != nil { updates.insert(.armsx2) }
                reports[.armsx2] = "Available · \(release.tagName)"
            } else {
                await ps2.install(workspace: store.workspaceURL, checkedRelease: release)
                reports[.armsx2] = ps2.status
                if ps2.installedVersion == release.tagName { updates.remove(.armsx2) }
            }
        } catch {
            reports[.armsx2] = error.localizedDescription
        }
    }

    private func runLegendary(_ operation: Operation, _ store: LibraryStore) async {
        if installed(.legendary, in: store) {
            if !storefronts.legendaryUpdateReady { await storefronts.downloadLegendaryUpdate(workspace: store.workspaceURL) }
            if storefronts.legendaryUpdateReady {
                updates.insert(.legendary)
                if operation != .check { await storefronts.installDownloadedLegendaryUpdate(workspace: store.workspaceURL) }
                if !storefronts.legendaryUpdateReady { updates.remove(.legendary) }
            }
        } else if operation == .install {
            await storefronts.installLegendary(workspace: store.workspaceURL)
        }
        reports[.legendary] = storefronts.status
    }

    private func runGOG(_ operation: Operation, _ store: LibraryStore) async {
        guard operation != .check else {
            reports[.gogdl] = "Choose Update to fast-forward the upstream checkout."
            return
        }
        await storefronts.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
        reports[.gogdl] = storefronts.status
    }

    nonisolated private static func read(_ url: URL, _ arguments: [String], multiline: Bool = false) -> String? {
        let command = Process()
        let pipe = Pipe()
        command.executableURL = url
        command.arguments = arguments
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        guard (try? command.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0,
              let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }
        return multiline ? result : result.components(separatedBy: .newlines).first
    }
}
