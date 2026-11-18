import Foundation

enum GameSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All Games", nxnative = "NXNative", steam = "Steam", crossover = "CrossOver", heroic = "Heroic", appStore = "App Store", native = "Native"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .nxnative: "cpu.fill"
        case .steam: "gearshape.2.fill"
        case .crossover: "square.stack.3d.up.fill"
        case .heroic: "shield.lefthalf.filled"
        case .appStore: "apple.logo"
        case .native: "desktopcomputer"
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
    var heroArt: ArtworkRecord? = nil
    var artworkMatchedTitle: String? = nil
    var artworkCheckedAt: Date? = nil
    var metadata: GameMetadata? = nil
    var isGameApp: Bool? = nil
    var runConfiguration: GameRunConfiguration? = nil
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
