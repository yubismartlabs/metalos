import SwiftUI

struct AddGameView: View {
    @EnvironmentObject var store: LibraryStore
    let onSwitch: () -> Void
    let onClose: () -> Void
    var startWithWindowsInstaller = false
    @StateObject private var wineInstaller = WindowsWineInstaller()
    @StateObject private var windowsInstaller = WindowsClientInstaller()
    @State private var selection = 0
    @State private var pickerPurpose: PickerPurpose?
    @State private var pending: (URL, PickerPurpose)?
    @State private var appToAdd: URL?
    @State private var appTitle = ""
    @State private var pendingWindowsGameExecutable: URL?
    @State private var windowsGameTitle = ""
    @State private var showAddConfirmation = false
    @State private var pendingBottleName: String?
    @State private var activeLutrisProfile: LutrisWineProfile?
    @State private var lutrisSearchOpen = false
    @State private var lutrisInstallOpen = false
    @State private var installStatus: String?
    @State private var isInstallingWindowsGame = false
    @State private var canRetryExecutableSelection = false
    private enum PickerPurpose { case macApp, ps2Disc, windowsInstaller, installedWindowsGame, existingWindowsGame }
    private let options = [
        ("Add a Mac app", "Choose a game or another .app.", "app"),
        ("Add a Switch game", "Choose its folder. Updates and DLC stay together; Play builds it for Mac.", "gamecontroller"),
        ("Add a PlayStation 2 game", "Choose a disc image. The file stays in its current location.", "opticaldisc"),
        ("Find a Windows game on Lutris", "Install a game from its published Lutris recipe.", "globe.americas.fill"),
        ("Install a Windows setup file", "Choose a Windows setup file. MetalOS prepares Wine automatically.", "pc"),
        ("Add an installed Windows game", "Choose its .exe from a MetalOS Wine prefix.", "folder.badge.plus"),
        ("Back to games", "", "arrow.uturn.backward")
    ]
    var body: some View {
        Group {
            if appToAdd != nil {
                SearchKeyboardView(query: $appTitle, title: "Name this game", subtitle: "Type with your Mac keyboard or use the on-screen gamepad keyboard.", doneTitle: "Add game", focusTextFieldOnAppear: true, onCancel: { self.appToAdd = nil }, onDone: addSelectedApp)
            } else if pendingWindowsGameExecutable != nil {
                SearchKeyboardView(query: $windowsGameTitle, title: "Name this Windows game", subtitle: "Change the suggested title or keep it. You can type with a keyboard or use the gamepad keyboard.", doneTitle: "Add game", focusTextFieldOnAppear: true, onCancel: cancelWindowsGameTitle, onDone: addSelectedWindowsGame)
            } else {
                addMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(studioBackground)
        .consolePage(isPresented: Binding(get: { pickerPurpose != nil }, set: { if !$0 { pickerPurpose = nil } }), onDismiss: finishSelection) {
            if let purpose = pickerPurpose {
                let mode: ConsoleFilePicker.Mode = purpose == .macApp ? .application : .file
                let startingPath: String? = {
                    switch purpose {
                    case .macApp: return "/Applications"
                    case .ps2Disc: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
                    case .windowsInstaller: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
                    case .installedWindowsGame:
                        guard let bottleName = pendingBottleName, let workspace = store.workspaceURL else { return nil }
                        if let profile = activeLutrisProfile, let executable = profile.executable {
                            let prefix = WindowsRuntimeLayout.winePrefix(forBottleAt: WindowsRuntimeLayout.bottle(bottleName, in: workspace))
                            return profile.resolveScriptPath(executable, prefix: prefix).path
                        }
                        return WindowsRuntimeLayout.bottle(bottleName, in: workspace).appendingPathComponent("prefix/drive_c", isDirectory: true).path
                    case .existingWindowsGame:
                        return store.workspaceURL.map { WindowsRuntimeLayout.bottles(in: $0).path }
                    }
                }()
                let title: String = purpose == .macApp ? "Choose a game application" : purpose == .ps2Disc ? "Choose a PlayStation 2 disc image" : purpose == .windowsInstaller ? "Choose a Windows setup executable" : "Choose the installed game executable"
                ConsoleFilePicker(title: title, mode: mode, startingPath: startingPath,
                                  allowedExtensions: purpose == .ps2Disc ? PS2GameDiscovery.extensions : purpose == .macApp ? [] : ["exe"]) { url in
                    pending = (url, purpose)
                    pickerPurpose = nil
                }
            }
        }
        .consolePage(isPresented: $showAddConfirmation) {
            ActionConfirmationView(title: "Add \(appTitle.isEmpty ? "this app" : appTitle)?", message: "MetalOS will add this app to your library using the title you entered. The app stays in its current location.", confirmTitle: "Add app", onConfirm: confirmSelectedApp)
        }
        .consolePage(isPresented: $lutrisSearchOpen) {
            LutrisSearchPage { profile in
                activeLutrisProfile = profile
                lutrisSearchOpen = false
                prepareLutrisRecipe()
            }
        }
        .consolePage(isPresented: $lutrisInstallOpen) {
            if let profile = activeLutrisProfile, let workspace = store.workspaceURL {
            LutrisRecipeInstallPage(profile: profile, workspace: workspace) { bottle in
                guard store.addPreparedLutrisBottle(at: bottle, profile: profile) else {
                    installStatus = store.notice ?? "The Lutris bottle could not be added to your library."
                        lutrisInstallOpen = false
                        return
                    }
                    lutrisInstallOpen = false
                    activeLutrisProfile = nil
                    onClose()
                }
            } else {
                Text("Choose a library folder before installing from Lutris.")
            }
        }
        .onAppear {
            if startWithWindowsInstaller { activeLutrisProfile = nil; pickerPurpose = .windowsInstaller }
        }
    }
    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Add to your collection").font(.system(size: 32, weight: .light))
            Text("Point MetalOS to a game or folder. The rest happens automatically.").foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { index in
                    Button { selection = index; activate() } label: {
                        HStack(spacing: 20) {
                            Image(systemName: options[index].2).font(.system(size: 24, weight: .light)).frame(width: 36)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(options[index].0).font(.system(size: 17, weight: .medium))
                                if !options[index].1.isEmpty { Text(options[index].1).font(.system(size: 12)).opacity(0.6) }
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(selection == index ? studioBackground : .white.opacity(0.85))
                            .background(selection == index ? studioAccent : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selection == index, cornerRadius: 13, scale: 1.025)
                        .disabled(isInstallingWindowsGame)
                        .accessibilityAddTraits(selection == index ? [.isSelected] : [])
                }
            }
            if isInstallingWindowsGame {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(studioAccent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(wineInstaller.isWorking ? "Preparing Windows support" : "Installing Windows game")
                            .font(.system(size: 13, weight: .medium))
                        Text(wineInstaller.isWorking ? wineInstaller.status : windowsInstaller.isWorking ? windowsInstaller.status : installStatus ?? "Preparing the installed game…")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            } else if let installStatus {
                Text(installStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                if canRetryExecutableSelection {
                    Button("Choose another game executable") { pickerPurpose = .existingWindowsGame }
                        .buttonStyle(.borderedProminent).tint(studioAccent)
                }
            }
            Text("↑ ↓  Choose     A / ×  Select     B / ○  Back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(30).frame(width: 740).background(studioBackground).preferredColorScheme(.dark)
            .animation(ConsoleFeedback.shared.focusAnimation, value: selection)
            .consoleInput { command in
                switch command {
                case "up", "left": selection = max(selection - 1, 0)
                case "down", "right": selection = min(selection + 1, options.count - 1)
                case "confirm": if !isInstallingWindowsGame { activate() }
                case "back", "menu", "context": if !isInstallingWindowsGame { onClose() }
                default: break
                }
            }
    }
    private func activate() {
        switch selection {
        case 0: pickerPurpose = .macApp
        case 1: onSwitch()
        case 2: pickerPurpose = .ps2Disc
        case 3: lutrisSearchOpen = true
        case 4: activeLutrisProfile = nil; pickerPurpose = .windowsInstaller
        case 5: pickerPurpose = .existingWindowsGame
        default: onClose()
        }
    }
    @MainActor
    private func prepareLutrisRecipe() {
        guard let workspace = store.workspaceURL else {
            installStatus = "Choose a library folder before installing games."
            return
        }
        Task {
            wineInstaller.refresh(workspace: workspace)
            let needsRuntime = wineInstaller.installedVersion == nil || wineInstaller.runtimeName.contains("legacy package")
            if needsRuntime { await wineInstaller.install(workspace: workspace) }
            guard wineInstaller.installedVersion != nil, !wineInstaller.runtimeName.contains("legacy package") else {
                installStatus = wineInstaller.status
                return
            }
            lutrisInstallOpen = true
        }
    }
    private func finishSelection() {
        guard let (url, purpose) = pending else { return }; pending = nil
        switch purpose {
        case .macApp:
            appToAdd = url
            appTitle = store.suggestedMacAppTitle(at: url)
        case .ps2Disc:
            if store.addPS2Game(at: url) { onClose() }
            else { installStatus = store.notice ?? "That PS2 disc image could not be added." }
        case .windowsInstaller:
            startWindowsInstaller(url, profile: activeLutrisProfile)
        case .installedWindowsGame, .existingWindowsGame:
            pendingBottleName = nil
            pendingWindowsGameExecutable = url
            windowsGameTitle = activeLutrisProfile?.gameName ?? WindowsExecutableIcon.suggestedTitle(for: url)
        }
    }
    private func cancelWindowsGameTitle() {
        pendingWindowsGameExecutable = nil
        windowsGameTitle = ""
    }
    private func addSelectedWindowsGame() {
        guard let executable = pendingWindowsGameExecutable else { return }
        let title = windowsGameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.addWindowsGame(at: executable, customTitle: title.isEmpty ? nil : title, lutrisProfile: activeLutrisProfile) else {
            installStatus = store.notice ?? "That executable could not be added. Choose the game’s executable inside the installed prefix."
            canRetryExecutableSelection = true
            pendingWindowsGameExecutable = nil
            return
        }
        pendingWindowsGameExecutable = nil
        canRetryExecutableSelection = false
        activeLutrisProfile = nil
        onClose()
    }
    @MainActor
    private func startWindowsInstaller(_ installerURL: URL, profile: LutrisWineProfile?) {
        Task { await installWindowsGame(at: installerURL, profile: profile) }
    }

    @MainActor
    private func installWindowsGame(at installerURL: URL, profile: LutrisWineProfile?) async {
        guard let workspace = store.workspaceURL else {
            installStatus = "Choose a library folder before installing games."
            return
        }
        isInstallingWindowsGame = true
        canRetryExecutableSelection = false
        installStatus = "Checking the Windows gaming runtime…"
        wineInstaller.refresh(workspace: workspace)
        let requiresRuntimeUpdate = wineInstaller.installedVersion == nil || wineInstaller.runtimeName.contains("legacy package")
        if requiresRuntimeUpdate {
            await wineInstaller.install(workspace: workspace)
        }
        guard wineInstaller.installedVersion != nil, !wineInstaller.runtimeName.contains("legacy package") else {
            installStatus = wineInstaller.status
            isInstallingWindowsGame = false
            return
        }
        installStatus = "Starting the Windows installer…"
        guard let bottle = await windowsInstaller.installStandaloneInstaller(at: installerURL, workspace: workspace, lutrisProfile: profile) else {
            installStatus = windowsInstaller.status
            isInstallingWindowsGame = false
            return
        }
        pendingBottleName = bottle
        installStatus = nil
        isInstallingWindowsGame = false
        pickerPurpose = .installedWindowsGame
    }
    private func addSelectedApp() {
        guard appToAdd != nil else { return }
        showAddConfirmation = true
    }
    private func confirmSelectedApp() {
        guard let appToAdd, store.addMacApp(at: appToAdd, title: appTitle) else { return }
        onClose()
    }
}
