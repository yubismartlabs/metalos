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
        case .usersGuide: "book.closed"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    var isPage = false
    var onClose: (() -> Void)? = nil

    @State private var path: [SettingsSection] = []
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
                .navigationDestination(for: SettingsSection.self) { section in
                    SettingsSectionPage(section: section)
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
        path.append(section)
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared

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

                Image(systemName: section.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text(section.rawValue)
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 24)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
    }
}
