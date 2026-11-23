import AppKit
import Combine
import GameController
import SwiftUI

enum ConsoleToastPriority: Equatable {
    case normal, success, warning

    var duration: TimeInterval {
        switch self {
        case .normal: 3.8
        case .success: 3.6
        case .warning: 5.2
        }
    }
}

struct ConsoleToast: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbol: String
    let priority: ConsoleToastPriority
    let deduplicationKey: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ConsoleToastManager: ObservableObject {
    static let shared = ConsoleToastManager()

    @Published private(set) var activeToast: ConsoleToast?
    @Published private(set) var queuedToasts: [ConsoleToast] = []

    private var observers: [NSObjectProtocol] = []
    private var batteryTimer: Timer?
    private var dismissalTask: Task<Void, Never>?
    private var warnedBatteryControllers: Set<ObjectIdentifier> = []
    private var recentKeys: [String: Date] = [:]
    private var started = false
    private var initialNetworkState: Bool?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observers = [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.controllerChanged(note) }
            }
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectControllerBatteries() }
        }
        inspectControllerBatteries()
    }

    func stop() {
        guard started else { return }
        started = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        batteryTimer?.invalidate()
        batteryTimer = nil
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    func post(_ title: String, _ subtitle: String, symbol: String = "bell.badge.fill",
              priority: ConsoleToastPriority = .normal, deduplicationKey: String? = nil) {
        let key = deduplicationKey ?? "\(title)|\(subtitle)"
        let now = Date()
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < 8 }
        guard recentKeys[key] == nil,
              activeToast?.deduplicationKey != key,
              !queuedToasts.contains(where: { $0.deduplicationKey == key }) else { return }
        recentKeys[key] = now
        let toast = ConsoleToast(id: UUID(), title: title, subtitle: subtitle, symbol: symbol,
                                 priority: priority, deduplicationKey: key)
        if activeToast == nil { show(toast) }
        else { queuedToasts.append(toast) }
    }

    func networkChanged(connected: Bool) {
        guard let previous = initialNetworkState else { initialNetworkState = connected; return }
        guard connected != previous else { return }
        initialNetworkState = connected
        if connected {
            post("Connected to Network", "Your internet connection is available again.", symbol: "wifi", priority: .success, deduplicationKey: "network-connected")
        } else {
            post("Internet Connection Lost", "Some online features may be unavailable.", symbol: "wifi.slash", priority: .warning, deduplicationKey: "network-offline")
        }
    }

    func refreshControllersAfterWake() {
        let count = GCController.controllers().count
        if count > 0 {
            post("Controllers Ready", "\(count) controller\(count == 1 ? " is" : "s are") connected after wake.",
                 symbol: "gamecontroller.fill", priority: .success, deduplicationKey: "controllers-after-wake-\(Calendar.current.ordinality(of: .hour, in: .day, for: .now) ?? 0)")
        }
        inspectControllerBatteries()
    }

    func notifyNewGames(_ count: Int) {
        guard count > 0 else { return }
        post("\(count) New Game\(count == 1 ? "" : "s") Added", "Your library is ready to explore.", symbol: "gamecontroller.fill", priority: .success)
    }

    func notifyMetadataRefresh() {
        post("Game Details Updated", "Artwork and information are ready.", symbol: "sparkles", priority: .success)
    }

    func notifyFavoriteAdded(_ added: Bool) {
        post(added ? "Added to Favorites" : "Removed from Favorites", "Your library has been updated.", symbol: added ? "heart.fill" : "heart", priority: .success)
    }

    func notifyHeroArtworkUpdated() {
        post("Hero Artwork Updated", "Your new background is ready.", symbol: "photo.fill", priority: .success)
    }

    func notifyProfileSwitched(_ profileName: String) {
        post("Profile Switched", "Now playing as \(profileName).", symbol: "person.crop.circle.fill", priority: .success)
    }

    func dismissActive() {
        guard activeToast != nil else { return }
        dismissalTask?.cancel()
        withAnimation(ConsoleMotion.zoneSpring) { activeToast = nil }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, self.activeToast == nil else { return }
            if !self.queuedToasts.isEmpty { self.show(self.queuedToasts.removeFirst()) }
        }
    }

    private func controllerChanged(_ note: Notification) {
        guard let controller = note.object as? GCController else { inspectControllerBatteries(); return }
        let name = controller.vendorName ?? "Game Controller"
        if note.name == .GCControllerDidConnect {
            let batteryText: String
            if let battery = controller.battery, battery.batteryLevel >= 0 {
                batteryText = "Connected · \(Int(battery.batteryLevel * 100))% Battery"
            } else { batteryText = "Connected and ready to play." }
            post(name, batteryText, symbol: "gamecontroller.fill", priority: .success, deduplicationKey: "controller-connect-\(name)")
        } else {
            warnedBatteryControllers.remove(ObjectIdentifier(controller))
            post("Controller Disconnected", name, symbol: "gamecontroller", priority: .normal, deduplicationKey: "controller-disconnect-\(name)")
        }
        inspectControllerBatteries()
    }

    private func inspectControllerBatteries() {
        let controllers = GCController.controllers()
        let currentIDs = Set(controllers.map(ObjectIdentifier.init))
        warnedBatteryControllers = warnedBatteryControllers.intersection(currentIDs)
        for controller in controllers {
            guard let battery = controller.battery else { continue }
            let id = ObjectIdentifier(controller)
            if battery.batteryState != .discharging || battery.batteryLevel < 0 || battery.batteryLevel >= 0.15 {
                warnedBatteryControllers.remove(id)
                continue
            }
            guard !warnedBatteryControllers.contains(id) else { continue }
            warnedBatteryControllers.insert(id)
            post("Controller Battery Low", "\(controller.vendorName ?? "Controller") is below 15%.",
                 symbol: "battery.25percent", priority: .warning, deduplicationKey: "controller-battery-\(id)")
        }
    }

    private func show(_ toast: ConsoleToast) {
        withAnimation(ConsoleMotion.zoneSpring) { activeToast = toast }
        UISoundManager.playNotificationToast()
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(toast.priority.duration))
            guard !Task.isCancelled, let self, self.activeToast?.id == toast.id else { return }
            self.dismissActive()
        }
    }
}

struct ConsoleToastLayer: View {
    @ObservedObject private var manager = ConsoleToastManager.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let toast = manager.activeToast {
                toastCard(toast)
                    .id(toast.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .topTrailing)), removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 40)
        .padding(.trailing, 52)
        .animation(ConsoleMotion.zoneSpring, value: manager.activeToast?.id)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func toastCard(_ toast: ConsoleToast) -> some View {
        HStack(spacing: 15) {
            Image(systemName: toast.symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(toast.priority == .warning ? Color.orange : Color.white)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(toast.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(toast.subtitle).font(.system(size: 13, weight: .regular)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 372, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 12)
    }
}
