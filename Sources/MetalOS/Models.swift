import Foundation

enum GameSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All Games", nxnative = "NXNative", ps2 = "PlayStation 2", steam = "Steam", epic = "Epic", gog = "GOG", battleNet = "Battle.net", windows = "Windows", crossover = "CrossOver", whisky = "Whisky", emulator = "Emulator", heroic = "Heroic", appStore = "App Store", native = "Native"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .nxnative: "cpu.fill"
        case .ps2: "gamecontroller.fill"
        case .steam: "gearshape.2.fill"
        case .epic: "e.square.fill"
        case .gog: "g.square.fill"
        case .battleNet: "b.square.fill"
        case .windows: "pc"
        case .crossover: "square.stack.3d.up.fill"
        case .whisky: "wineglass.fill"
        case .emulator: "gamecontroller.fill"
        case .heroic: "shield.lefthalf.filled"
        case .appStore: "apple.logo"
        case .native: "desktopcomputer"
        }
    }
}

enum WindowsGraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case vkd3d
    case dxvk
    case wine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic · DXMT / D3DMetal"
        case .vkd3d: "DirectX 12 · VKD3D-Proton"
        case .dxvk: "DirectX 8–11 · DXVK"
        case .wine: "WineD3D · OpenGL fallback"
        }
    }
    var detail: String {
        switch self {
        case .automatic: "Uses the runtime’s automatic Direct3D-to-Metal translation."
        case .vkd3d: "Uses VKD3D-Proton for DirectX 12 and DXVK for older Direct3D versions."
        case .dxvk: "Uses DXVK through MoltenVK for DirectX 8, 9, 10, and 11."
        case .wine: "Uses Wine’s OpenGL renderer as a compatibility fallback."
        }
    }
    var environmentValue: String? {
        switch self {
        case .automatic: nil
        case .vkd3d: "vkd3d"
        case .dxvk: "dxvk"
        case .wine: "wine"
        }
    }
}

enum WindowsCompatibilityRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
    case managedWine
    case gamePortingToolkit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .managedWine: "Managed Wine · MetalSharp"
        case .gamePortingToolkit: "Game Porting Toolkit · D3DMetal"
        }
    }
    var detail: String {
        switch self {
        case .managedWine: "Uses MetalSharp Wine with the selected DirectX renderer."
        case .gamePortingToolkit: "Uses Gcenx’s Apple Silicon Wine build with Apple D3DMetal for Direct3D 11/12."
        }
    }
}

struct Game: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var source: GameSource
    var launchURL: String
    var installPath: String
    var artworkPath: String? = nil
    var lastPlayed: Date? = nil
    var playedSeconds: TimeInterval? = nil
    var guideProfile: ConsoleGuideProfile? = nil
    var metalHUDEnabled: Bool? = nil
    var favorite: Bool = false
    var buildInput: String? = nil
    var forkPath: String? = nil
    var titleID: String? = nil
    var nxSupport: NXSupportStatus? = nil
    var builtNXProfileRevision: String? = nil
    var boxArt: ArtworkRecord? = nil
    var tileArt: ArtworkRecord? = nil
    var heroArt: ArtworkRecord? = nil
    var artworkMatchedTitle: String? = nil
    var artworkCheckedAt: Date? = nil
    var metadata: GameMetadata? = nil
    var isGameApp: Bool? = nil
    var runConfiguration: GameRunConfiguration? = nil
    var windowsExecutablePath: String? = nil
    var windowsBottlePath: String? = nil
    var highballLibraryID: String? = nil
    var highballBottleName: String? = nil
    var windowsStoreProvider: String? = nil
    var windowsStoreGameID: String? = nil
    var windowsGraphicsBackend: WindowsGraphicsBackend? = nil
    var windowsGraphicsBackendUserSet: Bool? = nil
    var windowsCompatibilityRuntime: WindowsCompatibilityRuntime? = nil
    var lutrisWineProfile: LutrisWineProfile? = nil
    var launchSpec: GameLaunchSpec? = nil
    var normalizedTitle: String? = nil
    var platformBadge: String? = nil
    var isHidden: Bool? = nil
    var collectionIDs: [String]? = nil
    var customTitle: String? = nil
    var gameDBId: Int? = nil
    var customArtworkPath: String? = nil
    var isGame: Bool { isGameApp ?? (source != .native || id.hasPrefix("app:") || id.hasPrefix("manual:")) }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: installPath) }
    var displayTitle: String { customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? metadata?.localizedTitle ?? title }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum GameLaunchSpec: Codable, Hashable, Sendable {
    case appBundle(appURL: URL, bundleID: String?)
    case steam(appID: String)
    case bottle(bottleName: String, bottlePath: URL, executableURL: URL, wrapperURL: URL?)
    case emulator(emulatorAppURL: URL, romURL: URL, arguments: [String])
}

struct EmulatorProfile: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var platformLabel: String
    var emulatorAppPath: String
    var romDirectoryPath: String
    var fileExtensions: [String]
    var argumentTemplate: [String]
    var enabled: Bool

    var emulatorAppURL: URL { URL(fileURLWithPath: NSString(string: emulatorAppPath).expandingTildeInPath) }
    var romDirectoryURL: URL { URL(fileURLWithPath: NSString(string: romDirectoryPath).expandingTildeInPath, isDirectory: true) }

    static var presets: [EmulatorProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            .init(id: "retroarch-snes", name: "RetroArch", platformLabel: "SNES", emulatorAppPath: "/Applications/RetroArch.app", romDirectoryPath: home.appendingPathComponent("Games/SNES").path, fileExtensions: ["sfc", "smc"], argumentTemplate: ["{rom}"], enabled: false),
            .init(id: "retroarch-gba", name: "RetroArch", platformLabel: "GBA", emulatorAppPath: "/Applications/RetroArch.app", romDirectoryPath: home.appendingPathComponent("Games/GBA").path, fileExtensions: ["gba"], argumentTemplate: ["{rom}"], enabled: false),
            .init(id: "dolphin", name: "Dolphin", platformLabel: "GameCube / Wii", emulatorAppPath: "/Applications/Dolphin.app", romDirectoryPath: home.appendingPathComponent("Games/Dolphin").path, fileExtensions: ["iso", "wbfs", "rvz", "gcm"], argumentTemplate: ["{rom}"], enabled: false),
            .init(id: "pcsx2", name: "PCSX2", platformLabel: "PS2", emulatorAppPath: "/Applications/PCSX2.app", romDirectoryPath: home.appendingPathComponent("Games/PS2").path, fileExtensions: ["iso", "chd", "cso"], argumentTemplate: ["{rom}"], enabled: false),
            .init(id: "ryujinx", name: "Ryujinx", platformLabel: "Switch", emulatorAppPath: "/Applications/Ryujinx.app", romDirectoryPath: home.appendingPathComponent("Games/Switch").path, fileExtensions: ["nsp", "xci"], argumentTemplate: ["{rom}"], enabled: false)
        ]
    }
}
struct GameRunConfiguration: Codable, Hashable, Sendable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
}
struct LauncherSettings: Codable, Equatable, Sendable {
    var workspacePath: String? = nil
    var forkPath = ""
    var pythonPath = NXBuildEnvironment.discoverPython() ?? "/usr/bin/python3"
    var keysPath = NXBuildEnvironment.discoverKeys() ?? ""
    var scanRoots: [String] = []
    var startInConsole = false
    var startGamesFullScreen: Bool? = nil
    var automaticallyFetchArtwork: Bool? = nil
    var homeWallpaperPath: String? = nil
    var homeParticlesEnabled: Bool? = nil
    var defaultWindowsRuntime: WindowsCompatibilityRuntime? = nil
    var emulatorProfiles: [EmulatorProfile]? = nil
}
struct LibraryData: Codable {
    var games: [Game] = []
    var settings = LauncherSettings()
}
struct DiscoveryResult: Sendable {
    var games: [Game] = []
    var warnings: [String] = []
}
enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
