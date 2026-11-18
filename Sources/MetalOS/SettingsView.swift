import SwiftUI
import AppKit

private enum ConsoleSettingsCategory: String, CaseIterable, Identifiable {
    case console = "Console", controllers = "Controllers", artwork = "Artwork", engine = "Engine", storage = "Library Folder"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .console: "display"
        case .controllers: "gamecontroller"
        case .artwork: "photo.on.rectangle.angled"
        case .engine: "cpu"
        case .storage: "externaldrive"
        }
    }
    var summary: String {
        switch self {
        case .console: "Make yourself at home."
        case .controllers: "Your controller. Your connection."
        case .artwork: "A face for every game."
        case .engine: "Install the MetalOS NXNative fork or choose your own checkout."
        case .storage: "Your Switch games and app data, together."
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var engineInstaller = NXNativeInstaller()
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var controllers = ControllerManager.shared
    @Environment(\.dismiss) var dismiss
    var isPage = false
    var onClose: (() -> Void)? = nil
    @State private var category = ConsoleSettingsCategory.console
    @State private var paneFocused = false
    @State private var editingVolume = false
    @State private var actionIndex = 0
    @State private var showControllers = false
    @State private var showTester = false
    @State private var pickerIndex: Int?
    @State private var selectInstalledFork = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "gearshape").font(.system(size: 27, weight: .light)).foregroundStyle(studioAccent)
                Text("Settings").font(.system(size: 34, weight: .light)).tracking(-0.7)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 34, height: 34).background(.white.opacity(0.05), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close settings")
            }.padding(.horizontal, 34).padding(.top, 28).padding(.bottom, 26)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ConsoleSettingsCategory.allCases) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 13) {
                                Image(systemName: item.symbol).font(.system(size: 17, weight: .light)).frame(width: 23)
                                Text(item.rawValue).font(.system(size: 14, weight: category == item ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }.foregroundStyle(category == item ? .white : .white.opacity(0.43))
                                .padding(.horizontal, 16).frame(height: 58)
                                .background(category == item ? .white.opacity(paneFocused ? 0.035 : 0.075) : .clear, in: RoundedRectangle(cornerRadius: 11))

                        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(category == item && !paneFocused, cornerRadius: 11, scale: 1.035).accessibilityAddTraits(category == item ? [.isSelected] : [])
                    }
                    Spacer()
                    Text("METALOS").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.2)).padding(16)
                }.padding(.horizontal, 18).frame(width: 245)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.rawValue).font(.system(size: 25, weight: .light))
                                Text(category.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                            }.padding(.bottom, 3)
                            settingsPane.id(category).transition(.opacity.combined(with: .offset(x: 16)))
                        }.padding(.horizontal, 30).padding(.bottom, 26)
                    }.onChange(of: actionIndex) { _, index in
                        if paneFocused { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("settings-action-\(index)", anchor: .center) } }
                    }
                }
            }
            HStack(spacing: 26) {
                Text("↑ ↓  Navigate")
                Text("A / ✕  Select")
                Text("B / ○  Back")
                Spacer()
                Text(paneFocused ? "←  Categories" : "→  Open category")
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 34).frame(height: 48)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
        }
            .frame(width: isPage ? nil : 920, height: isPage ? nil : 620)
            .frame(maxWidth: isPage ? .infinity : nil, maxHeight: isPage ? .infinity : nil)
            .background(studioBackground).preferredColorScheme(.dark).tint(studioAccent)
            .animation(feedback.focusAnimation, value: actionIndex)
            .animation(feedback.pageAnimation, value: category)
            .consoleInput(onCommand: navigate)
            .consoleSheet(isPresented: $showControllers) { ControllerStatusView() }
            .consoleSheet(isPresented: $showTester) {
                GamepadTesterView()
            }
            .consoleSheet(isPresented: $engineInstaller.confirmUpdate) {
                ActionConfirmationView(title: "NXNative update available", message: engineInstaller.updateStatus, confirmTitle: "Install update") {
                    Task {
                        await engineInstaller.installUpdate(checkoutPath: store.data.settings.forkPath)
                        await engineInstaller.refresh(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
                    }
                }
            }
            .consoleSheet(isPresented: Binding(get: { pickerIndex != nil }, set: { if !$0 { pickerIndex = nil } })) {
                if let index = pickerIndex {
                    if index == 1 {
                        ConsoleFilePicker(title: "Choose NXNative checkout", mode: .directory, startingPath: store.data.settings.forkPath.isEmpty ? store.workspacePath : store.data.settings.forkPath) { url in
                            pickerIndex = nil
                            guard NXBuildEnvironment.isCheckout(url.path) else {
                                store.notice = "Choose the NXNative folder containing scripts/build_ipa_from_nsp.py."
                                return
                            }
                            store.data.settings.forkPath = url.standardizedFileURL.path
                            store.save()
                            Task {
                                await engineInstaller.refresh(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
                                await engineInstaller.checkForUpdates(checkoutPath: store.data.settings.forkPath)
                            }
                        }
                    } else {
                        ConsoleFilePicker(title: "Choose Switch keys", mode: .file, startingPath: pickerStartingPath(index), allowedExtensions: ["keys"]) { url in
                            store.data.settings.keysPath = url.path
                            store.save(); pickerIndex = nil
                        }
                    }
                }
            }
            .onAppear {
                store.prepareArtwork(); controllers.refreshStatus()
                Task {
                    await engineInstaller.refresh(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
                    await engineInstaller.checkForUpdates(checkoutPath: store.data.settings.forkPath)
                }
            }
            .onDisappear { store.save() }
            .alert("Install NXNative requirements?", isPresented: $engineInstaller.confirmRequirements) {
                Button("Install requirements and continue") { Task { await installConfirmedEngine() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(engineInstaller.requirements.filter { !$0.ready && $0.canInstall }.map(\.id).joined(separator: ", "))
            }
            .alert("Finish setup first", isPresented: $engineInstaller.showManualHelp) {
                Button("Open requirements") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/yubismartlabs/nxnative#requirements")!)
                }
                Button("OK", role: .cancel) { }
            } message: { Text(engineInstaller.status) }
    }
    @ViewBuilder private var settingsPane: some View {
        switch category {
        case .console:
            actionRow(0, title: "Start in console mode", subtitle: "Open MetalOS full screen when you launch it.", symbol: "arrow.up.left.and.arrow.down.right", value: store.data.settings.startInConsole ? "On" : "Off")
            actionRow(1, title: "Console mode now", subtitle: "Switch between a desktop window and your full-screen game home.", symbol: "display", value: store.console ? "Full screen" : "Window")
            actionRow(2, title: "Navigation sounds", subtitle: "Soft sounds when you move, confirm, open a menu, or go back.", symbol: "speaker.wave.2", value: feedback.soundsEnabled ? "On" : "Off")
            actionRow(3, title: "Sound volume", subtitle: editingVolume ? "Left / Right adjusts volume. A or B finishes." : "Select to adjust the navigation sound level.", symbol: "speaker.wave.1", value: feedback.volumeText)
            if editingVolume {
                HStack(spacing: 16) {
                    Image(systemName: "speaker.fill")
                    ProgressView(value: feedback.volume, total: 1).tint(studioAccent)
                    Image(systemName: "speaker.wave.3.fill")
                }.foregroundStyle(studioAccent).padding(.horizontal, 18)
            }
            actionRow(4, title: "Reduce motion", subtitle: "Disable decorative motion. Your macOS Reduce Motion setting is also respected.", symbol: "figure.stand", value: feedback.reduceMotion ? "On" : "Off")
            actionRow(5, title: "Games start in full screen", subtitle: "Put a launched game into full screen. Requires Accessibility access the first time.", symbol: "arrow.up.left.and.arrow.down.right", value: store.data.settings.startGamesFullScreen != false ? "On" : "Off")
            note("Use the D-pad or left stick to browse, A / Cross to confirm, B / Circle to go back, and the shoulders to switch between Games and Media. Menu / Options and X / Square open game options.")
            note("Hold LB + RB and press Menu to open the in-game Game Bar. Games continue running while it is open.")
        case .controllers:
            if controllers.devices.isEmpty {
                note("No controller connected. Connect using Bluetooth or USB to see battery readings and available settings.")
            } else {
                ForEach(controllers.devices) { device in
                    HStack(spacing: 14) {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(studioAccent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(device.name).font(.system(size: 14, weight: .medium))
                            Text(device.batteryState.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: device.batterySymbol)
                        Text(device.batteryText).font(.system(size: 13)).monospacedDigit()
                    }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            actionRow(0, title: "Controller settings", subtitle: "Choose a controller, request light colors, open lighting help, assign a player, or test vibration.", symbol: "gamecontroller", value: "Open")
            actionRow(1, title: "Gamepad tester", subtitle: "Test every input. Hold B / Circle for one second to pause and choose another controller.", symbol: "gamecontroller.fill", value: "Test")
            note("Connect a compatible controller over Bluetooth or USB. Battery information depends on what the controller reports; unavailable readings are shown as unknown.")
            note("D-pad / left stick · Navigate\nA / Cross · Confirm\nB / Circle · Back\nX / Square · Game options\nMenu / Options · Game options")
        case .artwork:
            actionRow(0, title: "Scan Switch library", subtitle: "Find Switch game folders and refresh their artwork and details.", symbol: "arrow.clockwise", value: store.isScanning ? "Scanning" : "Scan", enabled: !store.isScanning)
            if store.isFetchingArtwork { ProgressView("Updating game artwork and details…").tint(studioAccent) }
            note(store.artworkStatus)
            note("MetalOS looks up artwork, descriptions, and screenshots after a game is added or found during a scan. Nothing needs to be matched by hand.")
        case .engine:
            HStack(spacing: 14) {
                Image(systemName: NXBuildEnvironment.isCheckout(store.data.settings.forkPath) ? "checkmark.circle.fill" : "cpu.fill")
                    .font(.system(size: 23)).foregroundStyle(studioAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("NXNative for Switch games").font(.system(size: 14, weight: .medium))
                    Text(NXBuildEnvironment.isCheckout(store.data.settings.forkPath) ? store.data.settings.forkPath : "Engine and requirements install inside your library folder.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
            }.padding(15).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            actionRow(0, title: engineInstaller.isWorking ? "Checking NXNative…" : NXBuildEnvironment.isCheckout(store.data.settings.forkPath) ? "Check engine requirements" : "Install NXNative",
                      subtitle: engineInstaller.status, symbol: engineInstaller.isWorking ? "arrow.trianglehead.2.clockwise.rotate.90" : "square.and.arrow.down", value: engineInstaller.isWorking ? "Working" : NXBuildEnvironment.isCheckout(store.data.settings.forkPath) ? "Check" : "Install", enabled: !engineInstaller.isWorking)
            actionRow(1, title: "NXNative folder", subtitle: NXBuildEnvironment.isCheckout(store.data.settings.forkPath) ? store.data.settings.forkPath : "Choose an existing NXNative checkout.", symbol: "folder", value: "Choose")
            if engineInstaller.isWorking { ProgressView().tint(studioAccent) }
            if !engineInstaller.requirements.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    Text("REQUIREMENTS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
                    ForEach(engineInstaller.requirements) { requirement in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: requirement.ready ? "checkmark.circle.fill" : requirement.canInstall ? "arrow.down.circle" : "exclamationmark.circle")
                                .font(.system(size: 12)).foregroundStyle(requirement.ready ? studioAccent : requirement.canInstall ? .white.opacity(0.6) : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(requirement.id).font(.system(size: 11, weight: .medium))
                                Text(requirement.detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.42)).lineLimit(2)
                            }
                            Spacer()
                            Text(requirement.ready ? "READY" : requirement.canInstall ? "INSTALL" : "REQUIRED")
                                .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(requirement.ready ? studioAccent : .white.opacity(0.4))
                        }
                    }
                }.padding(15).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            }
            actionRow(2, title: "Switch decryption keys", subtitle: store.data.settings.keysPath.isEmpty ? "MetalOS checks common emulator locations automatically." : store.data.settings.keysPath, symbol: "key", value: store.data.settings.keysPath.isEmpty ? "Optional" : "Change")
            actionRow(3, title: engineInstaller.updateAvailable ? "Install NXNative update" : "Check for NXNative updates", subtitle: engineInstaller.updateStatus, symbol: "arrow.triangle.2.circlepath", value: engineInstaller.updateAvailable ? "Install" : "Check", enabled: !engineInstaller.isWorking)
            actionRow(4, title: "Install Yubismartlabs NXNative fork", subtitle: "Install MetalOS’s default engine into your library folder and select it for builds.", symbol: "square.and.arrow.down", value: "Install", enabled: !engineInstaller.isWorking)
            Link("MetalOS NXNative fork requirements and setup", destination: URL(string: "https://github.com/yubismartlabs/nxnative#requirements")!).font(.caption)
        case .storage:
            actionRow(0, title: "Game library and app data", subtitle: store.workspacePath, symbol: "externaldrive", value: "Open")
            actionRow(1, title: "Scan Switch games", subtitle: store.isScanning ? "Checking this folder…" : "Find Switch game folders in your selected location.", symbol: "arrow.clockwise", value: store.isScanning ? "Scanning" : "Scan", enabled: !store.isScanning)
            note("Switch game folders, the NXNative engine, artwork, and MetalOS settings stay in this location.")
            if !store.scanWarnings.isEmpty { Text(store.scanWarnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    private func actionRow(_ index: Int, title: String, subtitle: String, symbol: String, value: String, enabled: Bool = true) -> some View {
        Button { paneFocused = true; actionIndex = index; perform(index) } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 28).foregroundStyle(paneFocused && actionIndex == index ? studioAccent : .white.opacity(0.65))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(enabled ? 0.9 : 0.4))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(enabled ? 0.65 : 0.25))
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
            }.padding(.horizontal, 17).padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(paneFocused && actionIndex == index ? 0.075 : 0.025), in: RoundedRectangle(cornerRadius: 11))

        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(paneFocused && actionIndex == index, cornerRadius: 11, scale: 1.02).disabled(!enabled).id("settings-action-\(index)")
            .accessibilityAddTraits(paneFocused && actionIndex == index ? [.isSelected] : [])
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.42)).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }
    private var actionCount: Int {
        switch category { case .console: 6; case .controllers: 2; case .artwork: 1; case .engine: 5; case .storage: 2 }
    }
    private func pickerStartingPath(_ index: Int) -> String? {
        index == 2 && !store.data.settings.keysPath.isEmpty ? store.data.settings.keysPath : nil
    }
    private func installEngine() {
        Task {
            if NXBuildEnvironment.isCheckout(store.data.settings.forkPath) {
                await engineInstaller.refresh(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath, checkoutPath: store.data.settings.forkPath)
            } else {
                selectInstalledFork = false
                await engineInstaller.install(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
            }
            syncInstalledEngine()
        }
    }
    private func installDefaultFork() {
        selectInstalledFork = true
        Task {
            await engineInstaller.install(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath)
            syncInstalledEngine()
        }
    }
    private func installConfirmedEngine() async {
        await engineInstaller.installConfirmedRequirements()
        syncInstalledEngine()
    }
    private func syncInstalledEngine() {
        if selectInstalledFork, let checkout = engineInstaller.installedCheckout {
            store.data.settings.forkPath = checkout
            selectInstalledFork = false
        } else if !NXBuildEnvironment.isCheckout(store.data.settings.forkPath), let checkout = engineInstaller.installedCheckout {
            store.data.settings.forkPath = checkout
        }
        if let python = engineInstaller.installedPython { store.data.settings.pythonPath = python }
        if !NXBuildEnvironment.isKeysFile(store.data.settings.keysPath), let keys = NXBuildEnvironment.discoverKeys() { store.data.settings.keysPath = keys }
        store.save()
    }
    private func select(_ next: ConsoleSettingsCategory) { category = next; paneFocused = false; actionIndex = 0; editingVolume = false }
    private func close() {
        store.save()
        if let onClose { onClose() } else { dismiss() }
    }
    private func navigate(_ command: String) {
        if editingVolume {
            switch command {
            case "left", "down", "previous": feedback.adjustVolume(-0.1)
            case "right", "up", "next": feedback.adjustVolume(0.1)
            case "confirm", "back", "menu", "context": editingVolume = false
            default: break
            }
            return
        }
        if showControllers { if command == "back" { showControllers = false }; return }
        switch command {
        case "up", "down":
            let delta = command == "up" ? -1 : 1
            if paneFocused { actionIndex = min(max(actionIndex + delta, 0), actionCount - 1) }
            else { changeCategory(delta) }
        case "left": paneFocused = false
        case "right": paneFocused = true
        case "confirm": if paneFocused { perform(actionIndex) } else { paneFocused = true }
        case "back": if paneFocused { paneFocused = false } else { close() }
        case "previous": changeCategory(-1)
        case "next": changeCategory(1)
        default: break
        }
    }
    private func changeCategory(_ delta: Int) {
        let all = ConsoleSettingsCategory.allCases
        let current = all.firstIndex(of: category) ?? 0
        select(all[(current + delta + all.count) % all.count])
    }
    private func perform(_ index: Int) {
        switch category {
        case .console:
            switch index {
            case 0: store.data.settings.startInConsole.toggle(); store.save()
            case 1: store.toggleConsole()
            case 2: feedback.soundsEnabled.toggle()
            case 3: editingVolume = true
            case 4: feedback.reduceMotion.toggle()
            case 5:
                store.data.settings.startGamesFullScreen = !(store.data.settings.startGamesFullScreen != false)
                store.save()
            default: break
            }
        case .controllers:
            if index == 0 { showControllers = true }
            else { showTester = true }
        case .artwork:
            if index == 0, !store.isScanning { Task { await store.scan() } }
        case .engine:
            if index == 0 { installEngine() }
            else if index == 1 { pickerIndex = 1 }
            else if index == 2 { pickerIndex = 2 }
            else if index == 3 {
                if engineInstaller.updateAvailable { engineInstaller.confirmUpdate = true }
                else { Task { await engineInstaller.checkForUpdates(checkoutPath: store.data.settings.forkPath) } }
            }
            else if index == 4 { installDefaultFork() }
        case .storage:
            if index == 0 {
                if let workspace = store.workspaceURL { NSWorkspace.shared.open(workspace) }
            } else if index == 1 {
                if !store.isScanning { Task { await store.scan() } }
            }
        }
    }
}
