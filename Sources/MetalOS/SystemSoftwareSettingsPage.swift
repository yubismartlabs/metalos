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
    @State private var showRequirementsConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEpicUpdateConfirmation = false
    @State private var showGOGUpdateConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showResetComplete = false
    @State private var selection = 0

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
    private var gogInstalled: Bool {
        guard let workspace = store.workspaceURL else { return false }
        return FileManager.default.isExecutableFile(atPath: epicRuntime.gogdlCLI(workspace: workspace).path)
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
                    group(title: "PLATFORM UPDATES", symbol: "square.grid.2x2") {
                        appRow(
                            title: "Epic Games",
                            detail: "Epic Games platform app",
                            engineNote: "Managed runtime: Legendary",
                            symbol: "e.square",
                            installed: epicInstalled,
                            progress: epicRuntime.isWorking ? epicRuntime.status : nil,
                            actionTitle: epicInstalled ? "Check for Updates" : "Install in Store",
                            disabled: !epicInstalled || epicRuntime.isWorking,
                            index: 0
                        ) {
                            Task { await checkEpicUpdates() }
                        }
                        divider
                        appRow(
                            title: "GOG",
                            detail: "GOG platform app",
                            engineNote: "Managed runtime: gogdl and its isolated Python environment",
                            symbol: "g.square",
                            installed: gogInstalled,
                            progress: epicRuntime.isWorking && gogInstalled ? epicRuntime.status : nil,
                            actionTitle: gogInstalled ? "Update" : "Install in Store",
                            disabled: !gogInstalled || epicRuntime.isWorking,
                            index: 1
                        ) {
                            showGOGUpdateConfirmation = true
                        }
                        divider
                        appRow(
                            title: "Switch",
                            detail: "Switch platform app",
                            engineNote: "Managed runtime: NXNative and available build requirements",
                            symbol: "gamecontroller",
                            installed: switchInstalled,
                            progress: nxNative.isWorking ? nxNative.status : nil,
                            actionTitle: switchInstalled ? "Check for Updates" : "Install in Store",
                            disabled: !switchInstalled || nxNative.isWorking,
                            index: 2
                        ) {
                            Task { await checkNXNativeUpdates() }
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
                                Text("Downloads available Epic Games and Switch updates when this page opens. GOG updates are started manually. Installation always requires your confirmation.")
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
                                .consoleFocus(selection == 3, cornerRadius: 18)
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
        .consolePage(isPresented: $showRequirementsConfirmation) {
            ActionConfirmationView(title: "Install required components?",
                                   message: "MetalOS will install the available build tools and Python packages required by the Switch app. Some Apple tools may still need to be installed manually.",
                                   confirmTitle: "Install components") {
                Task {
                    await nxNative.installConfirmedRequirements()
                    persistNXNativeRuntime()
                    await refreshNXNative()
                }
            }
        }
        .consolePage(isPresented: $showUpdateConfirmation) {
            ActionConfirmationView(title: "Install Switch app update?",
                                   message: "The update has been downloaded. Installing updates the NXNative component used by the Switch app.",
                                   confirmTitle: "Install update") {
                guard let checkout = nxCheckoutPath else { return }
                Task {
                    await nxNative.installUpdate(checkoutPath: checkout)
                    await refreshNXNative()
                }
            }
        }
        .consolePage(isPresented: $showEpicUpdateConfirmation) {
            ActionConfirmationView(title: "Install Epic Games app update?",
                                   message: "The verified update has been downloaded. Installing updates the Legendary runtime used by the Epic Games app.",
                                   confirmTitle: "Install update") {
                Task { await epicRuntime.installDownloadedLegendaryUpdate(workspace: store.workspaceURL) }
            }
        }
        .consolePage(isPresented: $showGOGUpdateConfirmation) {
            ActionConfirmationView(title: "Update GOG app?",
                                   message: "MetalOS will update gogdl and its isolated Python requirements for the GOG app.",
                                   confirmTitle: "Update GOG") {
                Task { await epicRuntime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
            }
        }
        .consolePage(isPresented: $showResetConfirmation) {
            ActionConfirmationView(title: "Reset MetalOS settings?",
                                   message: "MetalOS preferences and library configuration will return to their defaults. Your games, game files, and installed runtimes will remain in place.",
                                   confirmTitle: "Reset settings", destructive: true, onConfirm: resetSettings)
        }
        .consolePage(isPresented: $showResetComplete) {
            FullPageMessage(title: "Settings reset", message: "MetalOS preferences have been restored to their defaults.", symbol: "checkmark.circle.fill", buttonTitle: "Done")
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

    private func persistNXNativeRuntime() {
        if let checkout = nxNative.installedCheckout { store.data.settings.forkPath = checkout }
        if let python = nxNative.installedPython { store.data.settings.pythonPath = python }
        store.save()
    }

    private func checkNXNativeUpdates() async {
        guard let checkout = nxCheckoutPath else {
            return
        }
        await nxNative.checkForUpdates(checkoutPath: checkout)
        if nxNative.updateAvailable { showUpdateConfirmation = true }
    }

    private func checkEpicUpdates() async {
        await epicRuntime.downloadLegendaryUpdate(workspace: store.workspaceURL)
        if epicRuntime.legendaryUpdateReady { showEpicUpdateConfirmation = true }
    }

    private func downloadAvailableUpdates() async {
        await checkEpicUpdates()
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
        feedback.soundPack = .studio
        ConsolePreferences.shared.reset()
        showResetComplete = true
    }

    private func navigate(_ command: String) {
        switch command {
        case "up": selection = max(0, selection - 1)
        case "down": selection = min(3, selection + 1)
        case "confirm":
            if selection == 0 { Task { await checkEpicUpdates() } }
            else if selection == 1 { if gogInstalled { showGOGUpdateConfirmation = true } }
            else if selection == 2 { Task { await checkNXNativeUpdates() } }
            else { showResetConfirmation = true }
        case "back": dismiss()
        default: break
        }
    }
}
