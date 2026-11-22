import Foundation
import SwiftUI

struct ConsoleSaveState: Identifiable {
    let id: String
    let title: String
    let savedAt: Date
    let screenshotPath: String?
}

enum ConsoleRuntimeSetting: String, CaseIterable, Identifiable {
    case core = "Core Override"
    case graphics = "Graphics Backend"
    case upscaling = "Upscaling"
    case shader = "Shader Preset"
    case controller = "Controller Profile"
    case metalHUD = "Metal HUD on Launch"

    var id: Self { self }
}

struct ConsoleRuntimeOptions {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    let values: [Option]
    let selectedID: String?
    let apply: (Option.ID) throws -> Void
}

struct ConsoleFrameMetrics {
    var framesPerSecond: Double?
    var frameIntervalMilliseconds: Double?
    var gpuMilliseconds: Double?
}

/// A runtime registers only the operations it can perform for a particular game.
/// Session operations must target the supplied game's own live instance.
@MainActor
struct ConsoleGameRuntime {
    var states: ((Game) async throws -> [ConsoleSaveState])?
    var launchState: ((Game, ConsoleSaveState) async throws -> Void)?
    var quickSave: ((Game) async throws -> Void)?
    var quickLoad: ((Game) async throws -> Void)?
    var options: ((Game, ConsoleRuntimeSetting) -> ConsoleRuntimeOptions?)?
    var build: ((Game) -> String?)?
    var pipeline: ((Game) -> String?)?
    var frames: ((Game) -> ConsoleFrameMetrics?)?
}

@MainActor
final class ConsoleGameRuntimes: ObservableObject {
    static let shared = ConsoleGameRuntimes()
    @Published private(set) var providers: [GameSource: ConsoleGameRuntime] = [:]

    func register(_ provider: ConsoleGameRuntime?, for source: GameSource) {
        providers[source] = provider
    }
}

enum ConsoleGuideProfile: String, CaseIterable, Codable, Sendable {
    case southConfirm
    case eastConfirm

    var title: String {
        switch self {
        case .southConfirm: "Bottom button confirms"
        case .eastConfirm: "Right button confirms"
        }
    }

    var confirmGlyph: ConsolePromptControl { self == .southConfirm ? .confirm : .back }
    var backGlyph: ConsolePromptControl { self == .southConfirm ? .back : .confirm }

    func map(_ command: String) -> String {
        guard self == .eastConfirm else { return command }
        if command == "confirm" { return "back" }
        if command == "back" { return "confirm" }
        return command
    }
}
