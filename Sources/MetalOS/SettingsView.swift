import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case accessibility = "Accessibility"
    case network = "Network"
    case system = "System"
    case storage = "Storage"
    case sound = "Sound"
    case screenAndVideo = "Screen and Video"
    case notifications = "Notifications"
    case capturesAndBroadcasts = "Captures and Broadcasts"
    case accessories = "Accessories"
    case usersGuide = "Users Guide"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .network: "network"
        case .system: "gearshape.2"
        case .storage: "externaldrive"
        case .sound: "speaker.wave.2"
        case .screenAndVideo: "display"
        case .notifications: "bell"
        case .capturesAndBroadcasts: "record.circle"
        case .accessories: "gamecontroller"
        case .usersGuide: "book.closed"
        }
    }

    var summary: String? {
        switch self {
        case .network: "Connect to Wi-Fi or wired LAN, test internet speeds, and view connection status."
        case .storage: "Check available console space, manage games, and choose an installation location."
        case .sound: "Adjust the volume of console sound effects."
        case .screenAndVideo: "Configure resolution and other video settings."
        case .accessibility: "Enable screen zoom, screen reader, closed captions, custom button assignments, and menu navigation haptics."
        case .capturesAndBroadcasts: "Set screenshot and video resolutions, and customize Create button shortcuts."
        case .accessories: "Customize gamepads and test controller inputs."
        default: nil
        }
    }

    var features: [SystemFeature] {
        switch self {
        case .network:
            [
                SystemFeature(title: "Wi-Fi", detail: "Connect to a wireless network", symbol: "wifi"),
                SystemFeature(title: "Wired LAN", detail: "Connect through Ethernet", symbol: "cable.connector"),
                SystemFeature(title: "Internet Speed Test", detail: "Test your current connection speed", symbol: "speedometer"),
                SystemFeature(title: "Connection Status", detail: "View current network connection details", symbol: "network")
            ]
        case .storage:
            [
                SystemFeature(title: "Available Space", detail: "Check available space on your console", symbol: "internaldrive"),
                SystemFeature(title: "Move or Delete Games", detail: "Manage games in your library", symbol: "square.and.arrow.up.on.square"),
                SystemFeature(title: "Default Installation Location", detail: "Choose where new games are installed", symbol: "folder")
            ]
        case .sound:
            [SystemFeature(title: "Volume", detail: "Navigation sound effects", symbol: "speaker.wave.2")]
        case .screenAndVideo:
            [SystemFeature(title: "Resolution", detail: "Choose the display resolution", symbol: "display")]
        case .accessibility:
            [
                SystemFeature(title: "Screen Zoom", detail: "Magnify the screen", symbol: "plus.magnifyingglass"),
                SystemFeature(title: "Screen Reader", detail: "Read interface content aloud", symbol: "speaker.wave.3"),
                SystemFeature(title: "Closed Captions", detail: "Display captions where supported", symbol: "captions.bubble"),
                SystemFeature(title: "Custom Button Assignments", detail: "Change controller button assignments", symbol: "rectangle.on.rectangle"),
                SystemFeature(title: "Menu Navigation Haptics", detail: "Enable haptic feedback in menus", symbol: "hand.tap")
            ]
        case .capturesAndBroadcasts:
            [
                SystemFeature(title: "Screenshot Resolution", detail: "Set captured image resolution", symbol: "camera"),
                SystemFeature(title: "Video Resolution", detail: "Set captured video resolution", symbol: "video"),
                SystemFeature(title: "Create Button Shortcuts", detail: "Customize the Create button", symbol: "button.programmable")
            ]
        case .accessories:
            [
                SystemFeature(title: "Customize Gamepads", detail: "Controller options, lighting, player assignment, and vibration", symbol: "slider.horizontal.3"),
                SystemFeature(title: "Test Gamepad", detail: "Test buttons, sticks, triggers, and D-pad input", symbol: "gamecontroller")
            ]
        default:
            []
        }
    }
}

private enum SystemMenuItem: String, CaseIterable, Identifiable, Hashable {
    case systemSoftware = "System Software"
    case language = "Language"
    case dateAndTime = "Date and Time"
    case powerSaving = "Power Saving"
    case webBrowser = "Web Browser"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .systemSoftware: "arrow.down.circle"
        case .language: "character.bubble"
        case .dateAndTime: "calendar"
        case .powerSaving: "battery.100"
        case .webBrowser: "safari"
        }
    }

    var summary: String? {
        switch self {
        case .systemSoftware: "Check for and install system updates, manage automatic downloads, view App Information, or reset to factory defaults."
        case .language: "Change the Console Language and configure Input Languages for keyboards."
        case .dateAndTime: "Set the time zone, daylight saving, date and time formats, and internet clock sync."
        case .powerSaving: nil
        case .webBrowser: "Delete cookies and clear website data used by the built-in browser engine."
        }
    }

    var features: [SystemFeature] {
        switch self {
        case .systemSoftware:
            [
                SystemFeature(title: "Check for and install system updates", symbol: "arrow.clockwise"),
                SystemFeature(title: "Automatic update downloads", symbol: "arrow.down.to.line"),
                SystemFeature(title: "App Information", symbol: "info.circle"),
                SystemFeature(title: "Reset everything to factory defaults", symbol: "arrow.counterclockwise")
            ]
        case .language:
            [
                SystemFeature(title: "Console Language", symbol: "character.bubble"),
                SystemFeature(title: "Input Languages", detail: "On-screen keyboard and external keyboards", symbol: "keyboard")
            ]
        case .dateAndTime:
            [
                SystemFeature(title: "Time Zone", symbol: "globe"),
                SystemFeature(title: "Daylight Saving", symbol: "sun.max"),
                SystemFeature(title: "Date Format", symbol: "calendar"),
                SystemFeature(title: "Time Format", symbol: "clock"),
                SystemFeature(title: "Sync Clock via Internet", symbol: "arrow.triangle.2.circlepath")
            ]
        case .webBrowser:
            [
                SystemFeature(title: "Delete Cookies", symbol: "trash"),
                SystemFeature(title: "Clear Website Data", detail: "Data used by the console’s built-in browser engine", symbol: "globe")
            ]
        case .powerSaving:
            []
        }
    }
}

private enum SettingsRoute: Hashable {
    case section(SettingsSection)
    case systemItem(SystemMenuItem)
}

private struct SystemFeature: Identifiable {
    let title: String
    var detail: String? = nil
    let symbol: String
    var id: String { title }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    var isPage = false
    var onClose: (() -> Void)? = nil

    @State private var path: [SettingsRoute] = []
    @State private var selectedIndex = 0

    private var accent: Color { appearance.accent }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "gearshape")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(accent)
                Text("Settings")
                    .font(.system(size: 32, weight: .light))
                    .tracking(-0.6)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 34)
            .padding(.top, 27)
            .padding(.bottom, 22)

            NavigationStack(path: $path) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element.id) { index, section in
                                Button {
                                    selectedIndex = index
                                    open(section)
                                } label: {
                                    HStack(spacing: 17) {
                                        Image(systemName: section.symbol)
                                            .font(.system(size: 19, weight: .regular))
                                            .foregroundStyle(selectedIndex == index ? accent : .white.opacity(0.72))
                                            .frame(width: 28)
                                        Text(section.rawValue)
                                            .font(.system(size: 16, weight: selectedIndex == index ? .medium : .regular))
                                            .foregroundStyle(.white.opacity(0.92))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    .padding(.horizontal, 18)
                                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                                    .background {
                                        if selectedIndex == index {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(.white.opacity(0.065))
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(ConsoleButtonStyle())
                                .consoleFocus(selectedIndex == index, cornerRadius: 12, scale: 1.015)
                                .accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
                                .id(index)

                                if index < SettingsSection.allCases.count - 1 {
                                    Rectangle()
                                        .fill(.white.opacity(0.075))
                                        .frame(height: 1)
                                        .padding(.leading, 63)
                                }
                            }
                        }
                        .frame(maxWidth: 900)
                        .padding(.horizontal, 42)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .section(let section):
                        SettingsSectionPage(section: section) { item in
                            path.append(.systemItem(item))
                        }
                    case .systemItem(let item):
                        SystemMenuDetailPage(item: item)
                    }
                }
            }
            .background(Color.clear)

            HStack(spacing: 24) {
                Text("↑ ↓  Navigate")
                Text("A / ✕  Select")
                Text("B / ○  Back")
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 34)
            .frame(height: 46)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            }
        }
        .frame(width: isPage ? nil : 720, height: isPage ? nil : 690)
        .frame(maxWidth: isPage ? .infinity : nil, maxHeight: isPage ? .infinity : nil)
        .background {
            ZStack {
                appearance.background
                RadialGradient(colors: [accent.opacity(0.12), .clear], center: .topLeading, startRadius: 10, endRadius: 700)
                Rectangle().fill(.ultraThinMaterial).opacity(0.13)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .consoleInput(onCommand: navigate)
        .onAppear { store.prepareArtwork() }
        .onDisappear { store.save() }
    }

    private func open(_ section: SettingsSection) {
        path.append(.section(section))
    }

    private func navigate(_ command: String) {
        switch command {
        case "up": selectedIndex = (selectedIndex - 1 + SettingsSection.allCases.count) % SettingsSection.allCases.count
        case "down": selectedIndex = (selectedIndex + 1) % SettingsSection.allCases.count
        case "confirm":
            guard path.isEmpty else { return }
            open(SettingsSection.allCases[selectedIndex])
        case "back":
            if path.isEmpty { close() } else { path.removeLast() }
        default: break
        }
    }

    private func close() {
        store.save()
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct SettingsSectionPage: View {
    let section: SettingsSection
    var openSystemItem: (SystemMenuItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @State private var showControllerSettings = false
    @State private var showGamepadTester = false
    @State private var selectedFeatureIndex = 0

    var body: some View {
        if section == .system {
            SystemMenuPage(openSystemItem: openSystemItem)
        } else if section == .network {
            NetworkSettingsPage()
        } else {
            settingsPlaceholder
        }
    }

    private var settingsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Back to settings")

                Image(systemName: section.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text(section.rawValue)
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary = section.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !section.features.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(section.features.enumerated()), id: \.element.id) { index, feature in
                                Group {
                                    if section == .accessories {
                                        Button { activateAccessory(index) } label: { featureRow(feature) }
                                            .buttonStyle(ConsoleButtonStyle())
                                            .consoleFocus(selectedFeatureIndex == index, cornerRadius: 10, scale: 1.015)
                                    } else {
                                        featureRow(feature)
                                    }
                                }
                                if index < section.features.count - 1 {
                                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 58)
                                }
                            }
                        }
                        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 42)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .consoleSheet(isPresented: $showControllerSettings) { ControllerStatusView() }
        .consoleSheet(isPresented: $showGamepadTester) { GamepadTesterView() }
        .consoleInput(onCommand: navigate)
    }

    private func activateAccessory(_ index: Int) {
        selectedFeatureIndex = index
        if index == 0 { showControllerSettings = true }
        else { showGamepadTester = true }
    }

    private func navigate(_ command: String) {
        if command == "back" { dismiss(); return }
        guard section == .accessories else { return }
        switch command {
        case "up": selectedFeatureIndex = (selectedFeatureIndex - 1 + section.features.count) % section.features.count
        case "down": selectedFeatureIndex = (selectedFeatureIndex + 1) % section.features.count
        case "confirm": activateAccessory(selectedFeatureIndex)
        default: break
        }
    }

    @ViewBuilder private func featureRow(_ feature: SystemFeature) -> some View {
        HStack(spacing: 16) {
            Image(systemName: feature.symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(appearance.accent.opacity(0.88))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let detail = feature.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.44))
                }
            }
            Spacer()
            if section == .sound {
                Text(feedback.volumeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
                Slider(value: $feedback.volume, in: 0...1)
                    .tint(appearance.accent)
                    .frame(width: 220)
                    .accessibilityLabel("Volume")
            }
            if section == .accessories {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
    }
}

private struct SystemMenuPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @State private var selectedIndex = 0
    var openSystemItem: (SystemMenuItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Back to settings")

                Image(systemName: SettingsSection.system.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text(SettingsSection.system.rawValue)
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(SystemMenuItem.allCases.enumerated()), id: \.element.id) { index, item in
                        Button {
                            selectedIndex = index
                            openSystemItem(item)
                        } label: {
                            HStack(spacing: 17) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(appearance.accent.opacity(0.88))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.rawValue)
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.92))
                                    if let summary = item.summary {
                                        Text(summary)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.44))
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(ConsoleButtonStyle())
                        .consoleFocus(selectedIndex == index, cornerRadius: 12, scale: 1.015)
                        .accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
                        .id(index)

                        if index < SystemMenuItem.allCases.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.075))
                                .frame(height: 1)
                                .padding(.leading, 63)
                        }
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 42)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .consoleInput(onCommand: navigate)
    }

    private func navigate(_ command: String) {
        switch command {
        case "up": selectedIndex = (selectedIndex - 1 + SystemMenuItem.allCases.count) % SystemMenuItem.allCases.count
        case "down": selectedIndex = (selectedIndex + 1) % SystemMenuItem.allCases.count
        case "confirm":
            openSystemItem(SystemMenuItem.allCases[selectedIndex])
        case "back": dismiss()
        default: break
        }
    }
}

private struct SystemMenuDetailPage: View {
    let item: SystemMenuItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared

    var body: some View {
        if item == .systemSoftware {
            SystemSoftwareSettingsPage()
        } else {
            detailPage
        }
    }

    private var detailPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Back to System settings")

                Image(systemName: item.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text(item.rawValue)
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary = item.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.features.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(item.features.enumerated()), id: \.element.id) { index, feature in
                                HStack(spacing: 16) {
                                    Image(systemName: feature.symbol)
                                        .font(.system(size: 17, weight: .regular))
                                        .foregroundStyle(appearance.accent.opacity(0.88))
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(feature.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                        if let detail = feature.detail {
                                            Text(detail)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.44))
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                if index < item.features.count - 1 {
                                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 58)
                                }
                            }
                        }
                        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 42)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
    }
}
