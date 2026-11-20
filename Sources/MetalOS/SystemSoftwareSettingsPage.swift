import AppKit
import SwiftUI

struct SystemSoftwareSettingsPage: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @StateObject private var nxNative = NXNativeInstaller()
    @StateObject private var epicRuntime = WindowsStorefrontRuntime()
    @AppStorage("system.automaticUpdateDownloads") private var automaticDownloads = false
    @State private var pendingInstall: InstallTarget?
    @State private var showRequirementsConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEpicUpdateConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showResetComplete = false
    @State private var selection = 0

    private enum InstallTarget: String, Identifiable {
        case epic = "Epic Games"
        case switchApp = "Switch"
        var id: String { rawValue }
    }

    private var accent: Color { appearance.accent }
    private var epicInstalled: Bool {
        guard let workspace = store.workspaceURL else { return false }
        return FileManager.default.isExecutableFile(atPath: epicRuntime.legendaryCLI(workspace: workspace).path)
    }
    private var switchInstalled: Bool {
        guard let workspace = store.workspaceURL else { return false }
        let checkout = store.data.settings.forkPath
        if NXBuildEnvironment.isCheckout(checkout) { return true }
        return NXBuildEnvironment.isCheckout(workspace.appendingPathComponent(".nxstudio/Engines/NXNative-Yubismartlabs").path)
    }
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group(title: "CONSOLE APPS", symbol: "square.grid.2x2") {
                        appRow(
                            title: "Epic Games",
                            detail: "Install the Epic Games library and account support.",
                            engineNote: "Includes Legendary and its required runtime files.",
                            symbol: "e.square",
                            installed: epicInstalled,
                            progress: epicRuntime.isWorking ? epicRuntime.status : nil,
                            actionTitle: epicInstalled ? "Update" : "Install",
                            disabled: store.workspaceURL == nil || epicRuntime.isWorking,
                            index: 0
                        ) {
                            if epicRuntime.legendaryUpdateReady {
                                showEpicUpdateConfirmation = true
                            } else {
                                pendingInstall = .epic
                            }
                        }
                        divider
                        appRow(
                            title: "Switch",
                            detail: "Install tools to build and play supported Switch games on this Mac.",
                            engineNote: "Includes NXNative, Python build support, and required build tools when available.",
                            symbol: "gamecontroller",
                            installed: switchInstalled,
                            progress: nxNative.isWorking ? nxNative.status : nil,
                            actionTitle: switchInstalled ? "Update" : "Install",
                            disabled: store.workspaceURL == nil || nxNative.isWorking,
                            index: 1
                        ) {
                            if switchInstalled {
                                Task { await checkNXNativeUpdates() }
                            } else {
                                pendingInstall = .switchApp
                            }
                        }
                        Text(nxNative.updateStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.56))
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                    }

                    group(title: "UPDATE PREFERENCES", symbol: "arrow.down.to.line") {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Automatically download updates")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("Downloads available Epic Games and Switch app updates when this page opens. MetalOS will always ask before installing an update.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.48))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Toggle("Automatically download updates", isOn: $automaticDownloads)
                                .labelsHidden()
                                .tint(accent)
                                .accessibilityLabel("Automatically download updates")
                        }
                        .padding(18)
                    }

                    group(title: "METALOS", symbol: "info.circle") {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("App Information")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                            Text(appVersion)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(accent)
                            Text("MetalOS is a native macOS game library and console style interface. Console apps are installed and managed by MetalOS; engine and requirement details appear in each installation’s progress.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            divider
                            credit("MetalOS", detail: "NXStudio · SwiftUI and AppKit")
                            credit("NXNative", detail: "Yubismartlabs · Switch game build engine")
                            credit("Legendary", detail: "Legendary project · Epic Games library runtime")
                            credit("GameDB and IGDB", detail: "Game information and artwork providers")
                            credit("Apple", detail: "macOS, Swift, SwiftUI, Network, and system frameworks")
                        }
                        .padding(18)
                    }

                    group(title: "RESET", symbol: "arrow.counterclockwise") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reset everything to factory defaults")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("Resets MetalOS preferences and library configuration. Your game list, game files, and installed runtimes are kept.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.48))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Button("Reset") { showResetConfirmation = true }
                                .buttonStyle(ConsoleButtonStyle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.07), in: Capsule())
                                .consoleFocus(selection == 2, cornerRadius: 18)
                        }
                        .padding(18)
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
        .confirmationDialog("Install \(pendingInstall?.rawValue ?? "app")?", isPresented: Binding(
            get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }
        ), titleVisibility: .visible) {
            Button("Install \(pendingInstall?.rawValue ?? "App")") { confirmInstall() }
            Button("Cancel", role: .cancel) { pendingInstall = nil }
        } message: {
            Text(installDescription(for: pendingInstall))
        }
        .confirmationDialog("Install required components?", isPresented: $showRequirementsConfirmation, titleVisibility: .visible) {
            Button("Install Components") {
                Task {
                    await nxNative.installConfirmedRequirements()
                    await refreshNXNative()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("MetalOS will install the available build tools and Python packages required by the Switch app. Some Apple tools may still need to be installed manually.")
        }
        .confirmationDialog("Install Switch app update?", isPresented: $showUpdateConfirmation, titleVisibility: .visible) {
            Button("Install Update") {
                guard let checkout = nxCheckoutPath else { return }
                Task {
                    await nxNative.installUpdate(checkoutPath: checkout)
                    await refreshNXNative()
                }
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("The update has been downloaded. Installing updates the NXNative component used by the Switch app.")
        }
        .confirmationDialog("Install Epic Games app update?", isPresented: $showEpicUpdateConfirmation, titleVisibility: .visible) {
            Button("Install Update") {
                Task { await epicRuntime.installDownloadedLegendaryUpdate(workspace: store.workspaceURL) }
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("The verified update has been downloaded. Installing updates the Legendary runtime used by the Epic Games app.")
        }
        .alert("Reset MetalOS settings?", isPresented: $showResetConfirmation) {
            Button("Reset Settings", role: .destructive) { resetSettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("MetalOS preferences and library configuration will return to their defaults. Your games, game files, and installed runtimes will remain in place.")
        }
        .alert("Settings reset", isPresented: $showResetComplete) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("MetalOS preferences have been restored to their defaults.")
        }
        .onAppear { Task { await refreshOnOpen() } }
        .onChange(of: automaticDownloads) { _, enabled in
            guard enabled else { return }
            Task { await downloadAvailableUpdates() }
        }
        .consoleInput(onCommand: navigate)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(ConsoleButtonStyle())
            .accessibilityLabel("Back to System settings")
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(accent)
            Text("System Software")
                .font(.system(size: 28, weight: .light))
                .tracking(-0.4)
            Spacer()
        }
        .padding(.bottom, 24)
    }

    private func group<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.43))
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 10)
            content()
        }
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func appRow(title: String, detail: String, engineNote: String, symbol: String, installed: Bool, progress: String?, actionTitle: String, disabled: Bool, index: Int, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        Text(installed ? "INSTALLED" : "NOT INSTALLED")
                            .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(installed ? accent : .white.opacity(0.4))
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Text(engineNote).font(.system(size: 10)).foregroundStyle(.white.opacity(0.37))
                }
                Spacer(minLength: 8)
                Button(actionTitle, action: action)
                    .buttonStyle(ConsoleButtonStyle())
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(accent.opacity(0.15), in: Capsule())
                    .consoleFocus(selection == index, cornerRadius: 18)
                    .disabled(disabled)
                    .opacity(disabled ? 0.45 : 1)
            }
            if let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(accent)
                    Text(progress).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
                .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 62)
    }

    private func credit(_ name: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.82))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.44)).multilineTextAlignment(.trailing)
        }
    }

    private var nxCheckoutPath: String? {
        let configured = store.data.settings.forkPath
        if NXBuildEnvironment.isCheckout(configured) { return configured }
        guard let workspace = store.workspaceURL else { return nil }
        let managed = workspace.appendingPathComponent(".nxstudio/Engines/NXNative-Yubismartlabs").path
        return NXBuildEnvironment.isCheckout(managed) ? managed : nil
    }

    private func installDescription(for target: InstallTarget?) -> String {
        switch target {
        case .epic:
            "MetalOS will install the Epic Games app support, including the Legendary runtime and its verified macOS executable."
        case .switchApp:
            "MetalOS will install the Switch app support, including NXNative and any available Python or build tool requirements. You can review the components before they are installed."
        case nil: ""
        }
    }

    private func confirmInstall() {
        let target = pendingInstall
        pendingInstall = nil
        switch target {
        case .epic:
            Task { await epicRuntime.installLegendary(workspace: store.workspaceURL) }
        case .switchApp:
            Task {
                await nxNative.install(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
                if nxNative.confirmRequirements { showRequirementsConfirmation = true }
                await refreshNXNative()
            }
        case nil: break
        }
    }

    private func refreshOnOpen() async {
        if let workspace = store.workspaceURL {
            await nxNative.refresh(workspace: workspace, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
        }
        if automaticDownloads { await downloadAvailableUpdates() }
    }

    private func refreshNXNative() async {
        guard let workspace = store.workspaceURL else { return }
        await nxNative.refresh(workspace: workspace, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
    }

    private func checkNXNativeUpdates() async {
        guard let checkout = nxCheckoutPath else {
            return
        }
        await nxNative.checkForUpdates(checkoutPath: checkout)
        if nxNative.updateAvailable { showUpdateConfirmation = true }
    }

    private func downloadAvailableUpdates() async {
        await epicRuntime.downloadLegendaryUpdate(workspace: store.workspaceURL)
        if epicRuntime.legendaryUpdateReady { showEpicUpdateConfirmation = true }
        await checkNXNativeUpdates()
    }

    private func resetSettings() {
        let workspace = store.workspacePath
        store.data.settings = LauncherSettings()
        store.data.settings.workspacePath = workspace
        store.data.settings.scanRoots = workspace.isEmpty ? [] : [workspace]
        store.save()
        automaticDownloads = false
        appearance.theme = .emerald
        feedback.soundsEnabled = true
        feedback.volume = 0.35
        feedback.reduceMotion = false
        showResetComplete = true
    }

    private func navigate(_ command: String) {
        switch command {
        case "up": selection = max(0, selection - 1)
        case "down": selection = min(2, selection + 1)
        case "confirm":
            if selection == 0 { pendingInstall = .epic }
            else if selection == 1 { pendingInstall = .switchApp }
            else { showResetConfirmation = true }
        case "back": dismiss()
        default: break
        }
    }
}
