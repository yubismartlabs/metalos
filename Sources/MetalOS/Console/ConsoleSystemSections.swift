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
            Section(title: "System Software", symbol: "arrow.down.circle", rows: [
                firmware("Console Information", "MetalOS \(ConsoleMaintenance.appVersion)", detail: "Application and runtime version information."),
                firmware("System Software Update and Settings", "Up to date", detail: "Managed application updates are available from Updates."),
                firmware("Feature Information", "View available features", detail: "Review current MetalOS console features.")
            ]),
            Section(title: "Language", symbol: "character.bubble", rows: [
                firmware("Console Language", Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "System Default", detail: "The interface follows the macOS language."),
                firmware("Input Languages", "System managed", detail: "Keyboard input languages are configured in macOS.")
            ]),
            Section(title: "Date and Time", symbol: "calendar", rows: [
                firmware("Time Zone", TimeZone.current.identifier, detail: "Uses the time zone configured in macOS."),
                firmware("Time Format", DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") == true ? "12-hour" : "24-hour", detail: "Uses your regional format settings.")
            ]),
            Section(title: "Power Saving", symbol: "battery.100", rows: [
                firmware("Time Until Rest Mode", "System managed", detail: "Power behavior follows macOS energy settings."),
                firmware("Features Available in Rest Mode", "Background services", detail: "Library scans and update checks can run while MetalOS is open.")
            ]),
            Section(title: "HDMI", symbol: "cable.connector", rows: [
                firmware("Enable HDMI Device Link", "Display dependent", detail: "Device link support depends on the connected display."),
                firmware("HDCP", "Display dependent", detail: "Protected playback follows macOS and display support.")
            ]),
            Section(title: "Beep & Light", symbol: "lightbulb", rows: [
                firmware("Beep Volume", feedback.soundsEnabled ? feedback.volumeText : "Muted", detail: "Navigation sound volume for console menus."),
                firmware("Power Indicator Brightness", "System managed", detail: "No hardware power indicator is connected to MetalOS.")
            ]),
            Section(title: "Accessories", symbol: "gamecontroller", rows: [
                Row(title: "Bluetooth Accessories", detail: "View connected controllers and device status.", symbol: "dot.radiowaves.left.and.right", action: { sheet = .controllers }),
                Row(title: "Turn Off Accessories", detail: "Disconnect or power down supported devices.", value: "Open device controls", symbol: "power", action: { sheet = .controllers }),
                Row(title: "Controller Settings", detail: "Vibration, trigger effects, indicators, and communication method.", symbol: "slider.horizontal.3", action: { sheet = .controllers }),
                firmware("PlayStation VR2, Camera, and Media Remote", "Device dependent", detail: "Connect supported hardware to view its calibration and button options.")
            ]),
            Section(title: "Storage", symbol: "externaldrive", rows: [
                firmware("Console Storage", store.data.games.count.description + " games", detail: "Game and application files stored in the current library."),
                firmware("M.2 SSD Storage", "Not configured", detail: "Additional storage is managed by the selected library folder."),
                firmware("USB Extended Storage", "Not configured", detail: "External library folders can be added under Library & Paths."),
                firmware("Games and Apps · Media Gallery · Saved Data · Other", "Library managed", detail: "MetalOS stores games in your selected library and captures in Pictures / MetalOS.")
            ]),
            Section(title: "Screen and Video", symbol: "display", rows: [
                firmware("Resolution", NSScreen.main.map { "\(Int($0.frame.width)) × \(Int($0.frame.height))" } ?? "Display default", detail: "Uses the current macOS display mode."),
                firmware("VRR · 120 Hz · ALLM", "Display dependent", detail: "Refresh rate and latency features depend on macOS and the connected display."),
                firmware("HDR Calibration", "Display settings", detail: "Configure HDR in macOS Displays settings."),
                firmware("Adjust Display Area", "Full screen", detail: "Game windows use the available display area."),
                firmware("Dim Screen", "System managed", detail: "Display dimming is controlled by macOS.")
            ]),
            Section(title: "Sound", symbol: "speaker.wave.2", rows: [
                Row(title: "Microphone", detail: "Input device, input level, and login status are managed by macOS.", value: "System settings", symbol: "mic"),
                Row(title: "Audio Output", detail: "Output device and spatial audio are managed by macOS and the selected game.", value: "System settings", symbol: "hifispeaker"),
                toggle("Navigation Sounds", symbol: "speaker.wave.2", enabled: feedback.soundsEnabled) { feedback.soundsEnabled.toggle() },
                Row(title: "Volume", value: feedback.volumeText, symbol: "speaker.wave.2.fill", action: { sheet = .choices("Navigation Volume", stride(from: 0, through: 100, by: 10).map { value in
                    Choice(id: "\(value)%", selected: Int(feedback.volume * 100) == value, choose: { feedback.volume = Double(value) / 100 })
                }) })
            ]),
            Section(title: "Network", symbol: "network", rows: [
                firmware("Connection Status", "System managed", detail: "View Wi-Fi and LAN connections in macOS Network settings."),
                firmware("Test Internet Connection", "Available in Network settings", detail: "The active network connection is managed by macOS."),
                firmware("Set Up Internet Connection", "Wi-Fi / LAN", detail: "Configure wireless and wired networks in macOS System Settings.")
            ]),
            Section(title: "Users and Accounts", symbol: "person.crop.circle", rows: [
                firmware("Account Information", "Player 1", detail: "Local MetalOS profile."),
                firmware("Privacy Settings", "Local profile", detail: "Account privacy controls are not connected to an online console service."),
                firmware("Linked Services", "Discord · Spotify · Twitch · YouTube", detail: "Linked service integrations can be configured in their respective apps."),
                firmware("Login Settings", "macOS account", detail: "Device login and passcodes are managed by macOS.")
            ]),
            Section(title: "Captures and Broadcasts", symbol: "record.circle", rows: [
                firmware("Screenshot Resolution", "Display resolution", detail: "Captures use the current display resolution."),
                firmware("Video Clip Format", "MP4 / WebM", detail: "Capture output format depends on the recording tool."),
                firmware("Trophy Capture Triggers", "Not configured", detail: "Trophy capture triggers require a supported game runtime."),
                firmware("Broadcast Overlay Settings", "Game Bar", detail: "Open Game Bar while playing to manage capture overlays.")
            ]),
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
