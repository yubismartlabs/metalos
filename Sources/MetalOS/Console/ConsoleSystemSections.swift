import AppKit
import Metal
import SwiftUI

extension ConsoleSystemPage {
    var coreSections: [Section] {
        [
            Section(title: "Nintendo", symbol: "gamecontroller", rows: [
                component(.nxnative),
                firmware("Switch Keys", NXBuildEnvironment.isKeysFile(store.data.settings.keysPath) ? "Readable file" : "Required",
                         detail: "Use the keys file from your own console."),
                Row(title: "Choose Keys File", symbol: "key", action: { sheet = .switchKeys }),
                Row(title: "Build Requirements", symbol: "list.bullet.clipboard",
                    action: { sheet = .reader(.init(title: "NXNative requirements", body: requirementsText)) })
            ]),
            Section(title: "Sony", symbol: "opticaldisc", rows: [
                component(.armsx2),
                firmware("PlayStation 2 BIOS", "Managed by ARMSX2", detail: "Verify and select your BIOS in the emulator’s setup."),
                Row(title: "Open ARMSX2 Setup", detail: "Configure BIOS, graphics, and controller defaults.",
                    symbol: "slider.horizontal.3", enabled: maintenance.installed(.armsx2, in: store),
                    action: { maintenance.openPS2Setup(store) })
            ]),
            Section(title: "PC", symbol: "pc", rows: [
                component(.wine), component(.toolkit),
                choiceRow("Default Windows Runtime", "Applies to managed Windows games that use the PC default.",
                          symbol: "slider.horizontal.3", value: store.data.settings.defaultWindowsRuntime ?? .managedWine,
                          values: WindowsCompatibilityRuntime.allCases, label: \.title) {
                    store.data.settings.defaultWindowsRuntime = $0
                    store.save()
                },
                component(.legendary), component(.gogdl),
                Row(title: "Add Windows Game", symbol: "plus", action: { store.showGameImport = true })
            ]),
            Section(title: "Other", symbol: "square.stack", rows: [
                component(.native),
                firmware("Other Platform Cores", "No compatible adapter", detail: "Cores appear here when MetalOS has a compatible runtime integration.")
            ])
        ]
    }

    var updateSections: [Section] {
        [
            Section(title: "Overview", symbol: "arrow.down.circle", rows: [
                Row(title: "Update All", detail: "Check MetalOS and apply updates for installed managed runtimes.",
                    symbol: "arrow.down.to.line", enabled: !maintenance.isWorking, action: {
                    sheet = .confirm("Update installed runtimes?",
                                     "This checks MetalOS releases and applies updates to installed managed cores and storefront tools. The launcher release page handles app downloads.",
                                     "Update All") { maintenance.run(.all, store: store, channel: preferences.channel) }
                }),
                choiceRow("Launcher Release Channel", "The MetalOS release feed uses this channel. Runtime tools follow their own upstream feeds.",
                          symbol: "point.3.connected.trianglepath.dotted", value: preferences.channel,
                          values: ConsoleUpdateChannel.allCases, enabled: !maintenance.isWorking) { preferences.channel = $0 },
                component(.app)
            ] + releaseNoteRows(for: [.app])),
            Section(title: "Cores & Tools", symbol: "shippingbox", rows:
                ConsoleComponent.managed.flatMap { item in [component(item)] + releaseNoteRows(for: [item]) }),
            Section(title: "Databases", symbol: "cylinder.split.1x2", rows: [
                firmware("Shader Presets", "Runtime managed", detail: "MetalOS has no separate shader database feed."),
                firmware("Controller Mappings", "macOS managed", detail: "System controller profiles follow macOS and connected device updates."),
                Row(title: "Refresh Library Metadata", detail: "Fetch artwork and game metadata from the configured providers.",
                    symbol: "photo.on.rectangle", enabled: !store.isFetchingArtwork && store.canFetchArtwork,
                    action: { store.fetchArtwork(force: true) })
            ])
        ]
    }

    var customizationSections: [Section] {
        [
            Section(title: "Look & Layout", symbol: "paintbrush", rows: [
                choiceRow("Accent & Theme", "Changes the console’s accent and theme preset.", symbol: "paintpalette",
                          value: appearance.theme, values: StudioTheme.allCases, label: \.title) { appearance.theme = $0 },
                choiceRow("Ambient Artwork", "Adjust the glow behind your games.", symbol: "sun.max",
                          value: preferences.ambient, values: ConsoleAmbient.allCases) { preferences.ambient = $0 },
                choiceRow("Game Tile Size", "Set the density of the game rail.", symbol: "rectangle.grid.1x2",
                          value: preferences.density, values: ConsoleDensity.allCases) { preferences.density = $0 }
            ]),
            Section(title: "Backgrounds", symbol: "photo", rows: [
                Row(title: "Wallpaper Preset", value: currentWallpaperTitle, symbol: "photo.stack", action: {
                    sheet = .choices("Wallpaper Preset", WallpaperPreset.allCases.map { preset in
                        Choice(id: preset.title, selected: store.data.settings.homeWallpaperPath == preset.storageValue) {
                            store.data.settings.homeWallpaperPath = preset.storageValue
                            store.save()
                        }
                    })
                }),
                Row(title: "Import Background", detail: "Choose a still image or a looping video from disk.",
                    symbol: "folder", action: { sheet = .wallpaper })
            ]),
            Section(title: "Motion & Sound", symbol: "waveform", rows: [
                toggle("Boot Animation", detail: "Plays the intro when MetalOS starts.", symbol: "play.rectangle",
                       enabled: preferences.bootAnimation) { preferences.bootAnimation.toggle() },
                toggle("Navigation Sounds", symbol: "speaker.wave.2", enabled: feedback.soundsEnabled) { feedback.soundsEnabled.toggle() },
                choiceRow("Sound Pack", nil, symbol: "waveform", value: feedback.soundPack, values: ConsoleSoundPack.allCases) {
                    feedback.soundPack = $0
                    feedback.play(.toggle)
                }
            ]),
            Section(title: "Controller Glyphs", symbol: "gamecontroller", rows: [
                choiceRow("Prompt Style", "Auto follows the active controller and system remaps.",
                          symbol: "button.programmable", value: preferences.glyphs, values: ConsoleGlyphStyle.allCases) {
                    preferences.glyphs = $0
                }
            ])
        ]
    }

    var settingsSections: [Section] {
        [
            Section(title: "Display & Metal", symbol: "display", rows: [
                firmware("Metal Device", Self.metalDevice, detail: "Graphics device available to MetalOS."),
                toggle("Launch Games Full Screen", detail: "Requests full screen for supported game windows.",
                       symbol: "arrow.up.left.and.arrow.down.right", enabled: store.data.settings.startGamesFullScreen != false) {
                    store.data.settings.startGamesFullScreen = store.data.settings.startGamesFullScreen == false
                    store.save()
                },
                toggle("Reduce Motion", detail: "The macOS Reduce Motion setting also applies.",
                       symbol: "figure.walk.motion", enabled: feedback.reduceMotion) { feedback.reduceMotion.toggle() }
            ]),
            Section(title: "Audio", symbol: "speaker.wave.2", rows: [
                toggle("Navigation Sounds", symbol: "speaker.wave.2", enabled: feedback.soundsEnabled) { feedback.soundsEnabled.toggle() },
                Row(title: "Lower UI Volume", value: feedback.volumeText, symbol: "speaker.minus",
                    enabled: feedback.volume > 0, action: { feedback.adjustVolume(-0.05); feedback.play(.toggle) }),
                Row(title: "Raise UI Volume", value: feedback.volumeText, symbol: "speaker.plus",
                    enabled: feedback.volume < 1, action: { feedback.adjustVolume(0.05); feedback.play(.toggle) })
            ]),
            Section(title: "Controllers & Haptics", symbol: "gamecontroller", rows: [
                Row(title: "Connected Controllers", detail: "Check battery, button input, lights, and device features.",
                    symbol: "gamecontroller", action: { sheet = .controllers }),
                toggle("Navigation Haptics", detail: "Short feedback pulses on controllers that support haptics.",
                       symbol: "hand.tap", enabled: preferences.haptics) { preferences.haptics.toggle() }
            ]),
            Section(title: "Library & Paths", symbol: "folder", rows: libraryRows),
            Section(title: "Developer Options", symbol: "terminal", rows: [
                toggle("Verbose Performance HUD", detail: "Show runtime frame and GPU data when available.",
                       symbol: "speedometer", enabled: preferences.verboseHUD) { preferences.verboseHUD.toggle() },
                Row(title: "NXNative Build Log", symbol: "doc.text", action: {
                    sheet = .reader(.init(title: "NXNative Build Log", body: logExcerpt(store.builder.log)))
                }),
                Row(title: "Game Output", symbol: "terminal", action: {
                    sheet = .reader(.init(title: "Game Output", body: logExcerpt(store.gameConsoleLog)))
                }),
                firmware("Shader Cache", "Runtime managed", detail: "Use the runtime’s own settings to manage shader caches.")
            ]),
            Section(title: "System", symbol: "gearshape", rows: [
                firmware("MetalOS", ConsoleMaintenance.appVersion, detail: "Nintendo, Sony, PC, and macOS game library."),
                toggle("Start in Console Mode", symbol: "rectangle.inset.filled", enabled: store.data.settings.startInConsole) {
                    store.data.settings.startInConsole.toggle()
                    store.save()
                },
                Row(title: "Exit Console Mode", symbol: "rectangle.portrait.and.arrow.right", action: { store.toggleConsole() })
            ])
        ]
    }

    var requirementsText: String {
        let lines = maintenance.requirements.map { item in
            "\(item.ready ? "READY" : "NEEDED")  \(item.id)\n\(item.detail)"
        }
        return lines.isEmpty ? "Requirements have not been checked for this library folder." : lines.joined(separator: "\n\n")
    }

    private static let metalDevice = MTLCreateSystemDefaultDevice()?.name ?? "Unavailable"

    private var currentWallpaperTitle: String {
        guard let path = store.data.settings.homeWallpaperPath else { return WallpaperPreset.blueHorizon.title }
        return WallpaperPreset.fromStorageValue(path)?.title ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private var libraryRows: [Row] {
        var rows: [Row] = [
            firmware("Library Folder", store.workspacePath.isEmpty ? "Not configured" : store.workspacePath,
                     detail: "Managed runtimes and library data are stored here."),
            Row(title: "Add Scan Folder", symbol: "folder.badge.plus", action: { sheet = .scanFolder }),
            Row(title: store.isScanning ? "Scanning Library" : "Scan Library", key: "scan", symbol: "arrow.clockwise",
                enabled: !store.isScanning, action: { Task { await store.scan() } }),
            toggle("Fetch Artwork Automatically", symbol: "photo", enabled: store.data.settings.automaticallyFetchArtwork != false) {
                store.data.settings.automaticallyFetchArtwork = store.data.settings.automaticallyFetchArtwork == false
                store.save()
            }
        ]
        rows += store.data.settings.scanRoots.filter { $0 != store.workspacePath }.map { path in
            Row(title: "Remove Scan Folder", key: "remove:\(path)", detail: path, symbol: "folder.badge.minus", action: {
                sheet = .confirm("Remove scan folder?", path, "Remove Folder") {
                    store.data.settings.scanRoots.removeAll { $0 == path }
                    store.save()
                }
            })
        }
        return rows
    }

    private func component(_ item: ConsoleComponent) -> Row {
        let installed = maintenance.installed(item, in: store)
        let version = maintenance.versions[item] ?? (installed ? "Installed" : "Not installed")
        let report = maintenance.reports[item]
        let available = maintenance.updates.contains(item)
        let enabled = !maintenance.isWorking && store.workspaceURL != nil
        if item == .app {
            return Row(title: "Check for MetalOS Update", detail: report, value: ConsoleMaintenance.appVersion,
                       symbol: item.symbol, enabled: !maintenance.isWorking,
                       action: { maintenance.run(.check, item: item, store: store, channel: preferences.channel) })
        }
        if item == .native {
            return Row(title: item.rawValue, detail: "Uses the game’s macOS application. Firmware is not required.",
                       value: ProcessInfo.processInfo.operatingSystemVersionString, symbol: item.symbol)
        }
        let label: String
        let action: () -> Void
        if !installed {
            label = "Install"
            action = { run(.install, item) }
        } else if [.gogdl, .wine, .toolkit].contains(item) || available {
            label = "Update"
            action = { run(.install, item) }
        } else {
            label = "Check for Updates"
            action = { run(.check, item) }
        }
        return Row(title: "\(item.rawValue) · \(label)", key: item.rawValue,
                   detail: report ?? provenance(item), value: available ? "\(version) · Update available" : version,
                   symbol: item.symbol, enabled: enabled, action: action)
    }

    private func provenance(_ item: ConsoleComponent) -> String {
        switch item {
        case .nxnative: "Nintendo Switch · Configured Git upstream"
        case .armsx2: "PlayStation 2 · Apple Silicon nightly"
        case .legendary: "Epic Games · Upstream stable release"
        case .gogdl: "GOG · Upstream checkout"
        case .wine: "Managed Wine and its DirectX renderer"
        case .toolkit: "Gcenx Wine build with Apple D3DMetal"
        default: ""
        }
    }

    private func run(_ operation: ConsoleMaintenance.Operation, _ item: ConsoleComponent) {
        maintenance.run(operation, item: item, store: store, channel: preferences.channel)
    }

    private func releaseNoteRows(for items: [ConsoleComponent]) -> [Row] {
        items.compactMap { item in
            guard let note = maintenance.notes[item] else { return nil }
            return Row(title: "Read \(item.rawValue) Changelog", detail: note.title, symbol: "list.bullet.rectangle",
                       action: { sheet = .reader(note) })
        }
    }

    private func firmware(_ title: String, _ value: String, detail: String) -> Row {
        Row(title: title, detail: detail, value: value, symbol: "info.circle")
    }

    private func toggle(_ title: String, detail: String? = nil, symbol: String, enabled: Bool,
                        action: @escaping () -> Void) -> Row {
        Row(title: title, detail: detail, value: enabled ? "On" : "Off", symbol: symbol, action: action)
    }

    private func choiceRow<T: Equatable>(
        _ title: String, _ detail: String?, symbol: String, value: T, values: [T],
        label: @escaping (T) -> String, enabled: Bool = true, change: @escaping (T) -> Void
    ) -> Row {
        Row(title: title, detail: detail, value: label(value), symbol: symbol, enabled: enabled, action: {
            sheet = .choices(title, values.map { option in
                Choice(id: label(option), selected: value == option, choose: { change(option) })
            })
        })
    }

    private func choiceRow<T: RawRepresentable & Equatable>(
        _ title: String, _ detail: String?, symbol: String, value: T, values: [T],
        enabled: Bool = true, change: @escaping (T) -> Void
    ) -> Row where T.RawValue == String {
        choiceRow(title, detail, symbol: symbol, value: value, values: values, label: \.rawValue, enabled: enabled, change: change)
    }

    private func logExcerpt(_ log: String) -> String {
        if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No log output yet." }
        return String(log.suffix(24_000))
    }
}
