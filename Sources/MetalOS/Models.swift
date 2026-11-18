import Foundation

enum GameSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All Games", nxnative = "NXNative", steam = "Steam", epic = "Epic", gog = "GOG", battleNet = "Battle.net", windows = "Windows", crossover = "CrossOver", heroic = "Heroic", appStore = "App Store", native = "Native"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .nxnative: "cpu.fill"
        case .steam: "gearshape.2.fill"
        case .epic: "e.square.fill"
        case .gog: "g.square.fill"
        case .battleNet: "b.square.fill"
        case .windows: "pc"
        case .crossover: "square.stack.3d.up.fill"
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
        case .automatic: "Automatic · Mullion / DXMT"
        case .vkd3d: "VKD3D-Proton + DXVK · Vulkan"
        case .dxvk: "DXVK · D3D8–11"
        case .wine: "WineD3D · OpenGL fallback"
        }
    }
    var detail: String {
        switch self {
        case .automatic: "Uses MetalSharp Wine’s default Direct3D-to-Metal route."
        case .vkd3d: "Uses VKD3D-Proton for Direct3D 12 and DXVK for older Direct3D versions."
        case .dxvk: "Uses DXVK through MoltenVK for Direct3D 8–11."
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
    var isGame: Bool { isGameApp ?? (source != .native || id.hasPrefix("app:") || id.hasPrefix("manual:")) }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: installPath) }
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
