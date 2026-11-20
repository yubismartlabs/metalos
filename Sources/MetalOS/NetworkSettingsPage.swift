import AppKit
import Network
import SwiftUI

private struct NetworkPathSnapshot {
    var connected = false
    var headline = "Checking connection…"
    var detail = ""
    var wifiAvailable = false
    var wifiActive = false
    var wiredAvailable = false
    var wiredActive = false
}

@MainActor
private final class NetworkPathStatus: ObservableObject {
    @Published private(set) var snapshot = NetworkPathSnapshot()
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.nxstudio.network-path")

    init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifiAvailable = path.availableInterfaces.contains { $0.type == .wifi }
            let wiredAvailable = path.availableInterfaces.contains { $0.type == .wiredEthernet }
            let wifiActive = path.usesInterfaceType(.wifi)
            let wiredActive = path.usesInterfaceType(.wiredEthernet)
            let connected = path.status == .satisfied
            let activeTypes = [wifiActive ? "Wi-Fi" : nil, wiredActive ? "Wired LAN" : nil]
                .compactMap { $0 }
                .joined(separator: " and ")
            let next = NetworkPathSnapshot(
                connected: connected,
                headline: connected ? "Connected" : "Not connected",
                detail: connected
                    ? (activeTypes.isEmpty ? "Internet connection available" : "Using \(activeTypes)")
                    : "Connect using Wi-Fi or wired LAN.",
                wifiAvailable: wifiAvailable,
                wifiActive: wifiActive,
                wiredAvailable: wiredAvailable,
                wiredActive: wiredActive
            )
            DispatchQueue.main.async { self?.snapshot = next }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

@MainActor
private final class NetworkSpeedTest: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var result: String?
    @Published private(set) var error: String?

    func run() {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        error = nil
        Task {
            do {
                let download = try await measureDownload()
                let upload = try await measureUpload()
                result = "Download  \(download) Mbps     Upload  \(upload) Mbps"
            } catch {
                self.error = "Speed test failed: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    private func measureDownload() async throws -> Double {
        var components = URLComponents(string: "https://speed.cloudflare.com/__down")!
        components.queryItems = [
            URLQueryItem(name: "bytes", value: "10000000"),
            URLQueryItem(name: "nonce", value: UUID().uuidString)
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "GET"
        let start = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return megabitsPerSecond(bytes: data.count, elapsed: ProcessInfo.processInfo.systemUptime - start)
    }

    private func measureUpload() async throws -> Double {
        let payload = Data(repeating: 0x4D, count: 1_000_000)
        var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let start = ProcessInfo.processInfo.systemUptime
        let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
        try validate(response)
        return megabitsPerSecond(bytes: payload.count, elapsed: ProcessInfo.processInfo.systemUptime - start)
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func megabitsPerSecond(bytes: Int, elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return (Double(bytes) * 8 / elapsed) / 1_000_000
    }
}

struct NetworkSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @StateObject private var pathStatus = NetworkPathStatus()
    @StateObject private var speedTest = NetworkSpeedTest()
    @State private var selectedAction = 0

    private var accent: Color { appearance.accent }

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

                Image(systemName: "network")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(accent)
                Text("Network")
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CONNECTION STATUS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.42))
                        HStack(spacing: 12) {
                            Image(systemName: pathStatus.snapshot.connected ? "checkmark.circle.fill" : "wifi.slash")
                                .font(.system(size: 22))
                                .foregroundStyle(pathStatus.snapshot.connected ? accent : .white.opacity(0.55))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pathStatus.snapshot.headline)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text(pathStatus.snapshot.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                            Spacer()
                        }
                    }
                    .padding(20)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(spacing: 0) {
                        connectionRow(
                            title: "Wi-Fi",
                            detail: interfaceDetail(available: pathStatus.snapshot.wifiAvailable, active: pathStatus.snapshot.wifiActive),
                            symbol: "wifi",
                            index: 0
                        ) { openNetworkSettings() }
                        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 58)
                        connectionRow(
                            title: "Wired LAN",
                            detail: interfaceDetail(available: pathStatus.snapshot.wiredAvailable, active: pathStatus.snapshot.wiredActive),
                            symbol: "cable.connector",
                            index: 1
                        ) { openNetworkSettings() }
                    }
                    .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Internet Speed Test")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("Measures download and upload speed using Cloudflare.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.46))
                            }
                            Spacer()
                            Button {
                                selectedAction = 2
                                speedTest.run()
                            } label: {
                                HStack(spacing: 8) {
                                    if speedTest.isRunning { ProgressView().controlSize(.small).tint(.white) }
                                    Text(speedTest.isRunning ? "Testing…" : "Start Test")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(accent.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(ConsoleButtonStyle())
                            .consoleFocus(selectedAction == 2, cornerRadius: 18)
                            .disabled(speedTest.isRunning)
                        }
                        if let result = speedTest.result {
                            Text(result).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                        }
                        if let error = speedTest.error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private func connectionRow(title: String, detail: String, symbol: String, index: Int, action: @escaping () -> Void) -> some View {
        Button {
            selectedAction = index
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(accent.opacity(0.9))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.44))
                }
                Spacer()
                Text("Manage")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ConsoleButtonStyle())
        .consoleFocus(selectedAction == index, cornerRadius: 10, scale: 1.01)
    }

    private func interfaceDetail(available: Bool, active: Bool) -> String {
        if active { return "Connected and carrying traffic" }
        if available { return "Available" }
        return "Not currently available"
    }

    private func openNetworkSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func navigate(_ command: String) {
        switch command {
        case "up": selectedAction = max(0, selectedAction - 1)
        case "down": selectedAction = min(2, selectedAction + 1)
        case "confirm":
            if selectedAction < 2 { openNetworkSettings() } else { speedTest.run() }
        case "back": dismiss()
        default: break
        }
    }
}
