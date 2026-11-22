import AppKit
import SwiftUI
import UserNotifications

enum AppNotificationCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    case library
    case builds
    case games
    case artwork
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .builds: "Builds"
        case .games: "Games"
        case .artwork: "Artwork"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .builds: "hammer"
        case .games: "gamecontroller"
        case .artwork: "photo"
        case .system: "gearshape"
        }
    }
}

enum AppNotificationLevel: String, Codable, Equatable {
    case info, success, warning, error

    var symbol: String {
        switch self {
        case .info: "bell"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .white.opacity(0.66)
        case .success: Color(red: 0.36, green: 0.86, blue: 0.60)
        case .warning: Color(red: 1.0, green: 0.72, blue: 0.30)
        case .error: Color(red: 1.0, green: 0.38, blue: 0.40)
        }
    }
}

struct AppNotificationRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var message: String
    var date: Date
    var category: AppNotificationCategory
    var level: AppNotificationLevel
    var isRead: Bool

    init(title: String, message: String, category: AppNotificationCategory, level: AppNotificationLevel) {
        id = UUID()
        self.title = title
        self.message = message
        date = Date()
        self.category = category
        self.level = level
        isRead = false
    }
}

@MainActor
final class MetalOSNotificationCenter: ObservableObject {
    static let shared = MetalOSNotificationCenter()
    private static let recordsKey = "MetalOS.notificationHistory"
    private static let desktopEnabledKey = "MetalOS.desktopNotificationsEnabled"
    private static let desktopCategoriesKey = "MetalOS.desktopNotificationCategories"
    private let defaults = UserDefaults.standard

    @Published private(set) var records: [AppNotificationRecord]
    @Published private(set) var desktopAlertsEnabled: Bool
    @Published private(set) var desktopAuthorizationMessage = "Desktop alerts are off."
    @Published private(set) var enabledDesktopCategories: Set<AppNotificationCategory>
    @Published private(set) var toastRecord: AppNotificationRecord?
    private var toastDismissTask: Task<Void, Never>?

    var unreadCount: Int { records.reduce(into: 0) { if !$1.isRead { $0 += 1 } } }
    var desktopCategories: Set<AppNotificationCategory> { enabledDesktopCategories }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([AppNotificationRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        desktopAlertsEnabled = UserDefaults.standard.bool(forKey: Self.desktopEnabledKey)
        let storedCategories = UserDefaults.standard.stringArray(forKey: Self.desktopCategoriesKey) ?? AppNotificationCategory.allCases.map(\.rawValue)
        enabledDesktopCategories = Set(storedCategories.compactMap(AppNotificationCategory.init(rawValue:)))
        toastRecord = nil
    }

    func post(_ title: String, _ message: String, category: AppNotificationCategory, level: AppNotificationLevel = .info) {
        if records.contains(where: {
            $0.title == title && $0.message == message && Date().timeIntervalSince($0.date) < 4
        }) { return }

        let record = AppNotificationRecord(title: title, message: message, category: category, level: level)
        records.insert(record, at: 0)
        records = Array(records.prefix(250))
        persistRecords()

        if NSApp.isActive && (level == .info || level == .success) {
            toastDismissTask?.cancel()
            toastRecord = record
            toastDismissTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self.dismissToast(record.id)
            }
        }

        guard desktopAlertsEnabled, desktopCategories.contains(category), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func markRead(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isRead else { return }
        var updated = records
        updated[index].isRead = true
        records = updated
        persistRecords()
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        records = records.map { record in
            var updated = record
            updated.isRead = true
            return updated
        }
        persistRecords()
    }

    func clearHistory() {
        records.removeAll()
        persistRecords()
    }

    func dismissToast(_ id: UUID? = nil) {
        if let id, toastRecord?.id != id { return }
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastRecord = nil
    }

    func setDesktopCategory(_ category: AppNotificationCategory, enabled: Bool) {
        var categories = enabledDesktopCategories
        if enabled { categories.insert(category) } else { categories.remove(category) }
        enabledDesktopCategories = categories
        defaults.set(categories.map(\.rawValue).sorted(), forKey: Self.desktopCategoriesKey)
    }

    func setDesktopAlertsEnabled(_ enabled: Bool) {
        guard enabled != desktopAlertsEnabled else { return }
        guard enabled else {
            desktopAlertsEnabled = false
            defaults.set(false, forKey: Self.desktopEnabledKey)
            desktopAuthorizationMessage = "Desktop alerts are off."
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run {
                    self.desktopAlertsEnabled = authorized
                    self.defaults.set(authorized, forKey: Self.desktopEnabledKey)
                    self.desktopAuthorizationMessage = authorized
                        ? "Desktop alerts are enabled when MetalOS is in the background."
                        : "Allow MetalOS notifications in System Settings to enable desktop alerts."
                }
            } catch {
                await MainActor.run {
                    self.desktopAlertsEnabled = false
                    self.defaults.set(false, forKey: Self.desktopEnabledKey)
                    self.desktopAuthorizationMessage = "Could not enable desktop alerts: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshAuthorizationMessage() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                if self.desktopAlertsEnabled && settings.authorizationStatus != .authorized {
                    self.desktopAuthorizationMessage = "Allow MetalOS notifications in System Settings to receive desktop alerts."
                } else if self.desktopAlertsEnabled {
                    self.desktopAuthorizationMessage = "Desktop alerts are enabled when MetalOS is in the background."
                } else {
                    self.desktopAuthorizationMessage = "Desktop alerts are off. In-app notifications are always available."
                }
            }
        }
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.recordsKey) }
    }
}

struct NotificationCenterPanel: View {
    @ObservedObject private var center = MetalOSNotificationCenter.shared
    @ObservedObject private var appearance = StudioAppearance.shared
    let close: () -> Void
    @State private var selectedCategory: AppNotificationCategory?
    @State private var unreadOnly = false
    @State private var selectedRecordIndex = 0

    private var visibleRecords: [AppNotificationRecord] {
        center.records.filter { (!unreadOnly || !$0.isRead) && (selectedCategory == nil || $0.category == selectedCategory) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill").foregroundStyle(appearance.accent)
                Text("Notifications").font(.system(size: 23, weight: .medium))
                if center.unreadCount > 0 {
                    Text("\(center.unreadCount)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(appearance.accent, in: Capsule()).foregroundStyle(.black)
                }
                Spacer()
                Button("Mark all read") { center.markAllRead() }.disabled(center.unreadCount == 0)
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).accessibilityLabel("Close notifications")
            }
            .padding(20)

            HStack(spacing: 8) {
                filterChip("All", selected: !unreadOnly && selectedCategory == nil) { unreadOnly = false; selectedCategory = nil }
                filterChip("Unread", selected: unreadOnly) { unreadOnly.toggle(); selectedCategory = nil }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AppNotificationCategory.allCases) { category in
                            filterChip(category.title, selected: selectedCategory == category) {
                                selectedCategory = selectedCategory == category ? nil : category
                                unreadOnly = false
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if visibleRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    Text(unreadOnly ? "You’re all caught up" : "No notifications yet").font(.system(size: 15, weight: .medium))
                    Text("Builds, library changes, and game activity will appear here.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { entry in
                            NotificationRow(record: entry.element, selected: selectedRecordIndex == entry.offset) { center.markRead(entry.element.id) }
                        }
                    }
                    .padding(14)
                }
            }

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack {
                Text("Most recent \(min(center.records.count, 250)) notifications saved on this Mac")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                Spacer()
                Button("Clear history") { center.clearHistory() }
                    .font(.system(size: 11)).disabled(center.records.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .padding(.horizontal, 42).padding(.vertical, 30)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .consoleInput(onCommand: navigate)
    }

    private func navigate(_ command: String) {
        switch command {
        case "back", "menu": close()
        case "up": selectedRecordIndex = max(0, selectedRecordIndex - 1)
        case "down": selectedRecordIndex = min(max(visibleRecords.count - 1, 0), selectedRecordIndex + 1)
        case "confirm":
            if visibleRecords.indices.contains(selectedRecordIndex) { center.markRead(visibleRecords[selectedRecordIndex].id) }
        case "left", "previous", "right", "next":
            let direction = command == "left" || command == "previous" ? -1 : 1
            let categories: [AppNotificationCategory?] = [nil] + AppNotificationCategory.allCases.map(Optional.some)
            let current = categories.firstIndex(where: { $0 == selectedCategory }) ?? 0
            let next = (current + direction + categories.count) % categories.count
            selectedCategory = categories[next]
            unreadOnly = false
            selectedRecordIndex = 0
        default: break
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .black : .white.opacity(0.72))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? appearance.accent : .white.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct NotificationRow: View {
    let record: AppNotificationRecord
    let selected: Bool
    let markRead: () -> Void

    var body: some View {
        Button(action: markRead) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.level.symbol).font(.system(size: 15)).foregroundStyle(record.level.color).frame(width: 22, height: 24)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                        Spacer(minLength: 8)
                        Text(record.date.formatted(.relative(presentation: .named))).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                    Text(record.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.68)).multilineTextAlignment(.leading).lineLimit(3)
                    Label(record.category.title, systemImage: record.category.symbol)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                }
                if !record.isRead { Circle().fill(Color(red: 0.3, green: 0.78, blue: 1)).frame(width: 6, height: 6).padding(.top, 8) }
            }
            .padding(13)
            .background(.white.opacity(selected ? 0.12 : record.isRead ? 0.035 : 0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .consoleFocus(selected, cornerRadius: 12, scale: 1.015)
        }.buttonStyle(.plain).accessibilityLabel("\(record.title). \(record.message). \(record.isRead ? "Read" : "Unread")")
    }
}

struct NotificationToastView: View {
    let record: AppNotificationRecord
    let openCenter: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.level.symbol).foregroundStyle(record.level.color).font(.system(size: 16))
            Button(action: openCenter) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(record.message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.68)).lineLimit(2)
                }
            }.buttonStyle(.plain).frame(maxWidth: 350, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.58)).accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
        .accessibilityElement(children: .contain)
    }
}

struct NotificationSettingsPage: View {
    @ObservedObject private var center = MetalOSNotificationCenter.shared
    @ObservedObject private var appearance = StudioAppearance.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSettingIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Back to settings")
                Image(systemName: "bell.badge").font(.system(size: 22, weight: .light)).foregroundStyle(appearance.accent)
                Text("Notifications").font(.system(size: 28, weight: .light)).tracking(-0.4)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("IN-APP NOTIFICATIONS")
                        .font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(.white.opacity(0.52))
                    settingsCard {
                        settingsRow("Notification history", detail: "Keep up to 250 recent alerts in the notification center.", symbol: "tray.full", isOn: .constant(true), disabled: true)
                    }
                    Text("DESKTOP ALERTS")
                        .font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(.white.opacity(0.52)).padding(.top, 8)
                    settingsCard {
                        settingsRow("Allow desktop notifications", detail: center.desktopAuthorizationMessage, symbol: "macbook.and.iphone",
                                    isOn: Binding(get: { center.desktopAlertsEnabled }, set: { center.setDesktopAlertsEnabled($0) }),
                                    focused: selectedSettingIndex == 0)
                    }
                    if center.desktopAlertsEnabled {
                        Text("SEND DESKTOP ALERTS FOR")
                            .font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(.white.opacity(0.52)).padding(.top, 8)
                        settingsCard {
                            VStack(spacing: 0) {
                                ForEach(Array(AppNotificationCategory.allCases.enumerated()), id: \.element.id) { item in
                                    let category = item.element
                                    settingsRow(category.title, detail: detail(for: category), symbol: category.symbol,
                                                isOn: Binding(get: { center.desktopCategories.contains(category) }, set: { center.setDesktopCategory(category, enabled: $0) }),
                                                focused: selectedSettingIndex == item.offset + 1)
                                    if category != AppNotificationCategory.allCases.last { Divider().overlay(.white.opacity(0.08)).padding(.leading, 54) }
                                }
                            }
                        }
                    }
                    Text("Desktop alerts appear only while MetalOS is in the background. In-app history and unread counts remain available at all times.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42)).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }.frame(maxWidth: 800, alignment: .leading).padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 34).padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .onAppear { center.refreshAuthorizationMessage() }
        .consoleInput(onCommand: navigate)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private func settingsRow(_ title: String, detail: String, symbol: String, isOn: Binding<Bool>, disabled: Bool = false, focused: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(appearance.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden().tint(appearance.accent).disabled(disabled)
                .consoleFocus(focused, cornerRadius: 8, scale: 1.04)
        }
        .padding(15)
        .background(focused ? .white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func navigate(_ command: String) {
        let lastIndex = center.desktopAlertsEnabled ? AppNotificationCategory.allCases.count : 0
        switch command {
        case "back", "menu": dismiss()
        case "up": selectedSettingIndex = max(0, selectedSettingIndex - 1)
        case "down": selectedSettingIndex = min(lastIndex, selectedSettingIndex + 1)
        case "confirm":
            if selectedSettingIndex == 0 { center.setDesktopAlertsEnabled(!center.desktopAlertsEnabled) }
            else {
                let categories = AppNotificationCategory.allCases
                let categoryIndex = selectedSettingIndex - 1
                if categories.indices.contains(categoryIndex) {
                    let category = categories[categoryIndex]
                    center.setDesktopCategory(category, enabled: !center.desktopCategories.contains(category))
                }
            }
        default: break
        }
    }

    private func detail(for category: AppNotificationCategory) -> String {
        switch category {
        case .library: "Library scans, game imports, and store activity"
        case .builds: "NXNative build completion, failure, and cancellation"
        case .games: "Game launch and session events"
        case .artwork: "Artwork and metadata refreshes"
        case .system: "Setup, settings, and other errors"
        }
    }
}
