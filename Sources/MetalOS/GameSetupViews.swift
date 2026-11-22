import SwiftUI
import AppKit

struct ActionConfirmationView: View {
    @Environment(\.consolePageClose) private var closePage
    @State private var selection = 0
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = false
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 13) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 27, weight: .light)).foregroundStyle(destructive ? .orange : studioAccent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONFIRM ACTION").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(studioAccent)
                    Text(title).font(.system(size: 25, weight: .light))
                }
            }
            Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.66)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                confirmRow(confirmTitle, symbol: destructive ? "trash" : "checkmark", selected: selection == 0, destructive: destructive) { onConfirm(); closePage() }
                confirmRow("Cancel", symbol: "xmark", selected: selection == 1, destructive: false) { closePage() }
            }
            Text("↑ ↓  Choose     A / ×  Confirm     B / ○  Cancel").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(studioBackground.ignoresSafeArea()).preferredColorScheme(.dark)
            .animation(ConsoleFeedback.shared.focusAnimation, value: selection)
            .consoleInput { command in
                switch command {
                case "up", "left": selection = max(selection - 1, 0)
                case "down", "right": selection = min(selection + 1, 1)
                case "confirm": if selection == 0 { onConfirm(); closePage() } else { closePage() }
                case "back": closePage()
                default: break
                }
            }
    }

    private func confirmRow(_ label: String, symbol: String, selected: Bool, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 18)
                Text(label).font(.system(size: 13, weight: .semibold))
                Spacer()
                if selected { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
            }.padding(.horizontal, 15).frame(height: 46)
                .foregroundStyle(selected ? .white : .white.opacity(0.76))
                .background(selected ? (destructive ? Color.red.opacity(0.76) : studioAccent) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selected, cornerRadius: 9, scale: 1.02)
    }
}

struct ConsoleActionRow: View {
    var title: String
    var value: String
    var symbol: String
    var selected: Bool
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 28)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    if !value.isEmpty { Text(value).font(.system(size: 11)).opacity(0.55).lineLimit(2).truncationMode(.middle) }
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selected ? studioBackground : .white.opacity(enabled ? 0.85 : 0.35))
                .background(selected ? studioAccent : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selected, cornerRadius: 11, scale: 1.02).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
struct SwitchImportView: View {
    @EnvironmentObject var store: LibraryStore
    let onClose: () -> Void
    private enum PackageKind: Equatable { case base, update, dlc }
    @State private var baseGame: URL?
    @State private var update: URL?
    @State private var dlcs: [URL] = []
    @State private var selection = 0
    @State private var picker: PackageKind?
    @State private var showAddConfirmation = false
    private var canAdd: Bool { baseGame != nil }
    private var title: String {
        guard let baseGame else { return "Choose the base game file" }
        let parsed = GameTitleMatcher.searchTitle(baseGame.lastPathComponent)
        return parsed.isEmpty ? baseGame.deletingPathExtension().lastPathComponent : parsed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Switch game").font(.system(size: 30, weight: .light))
            Text("Choose the base game and any update or DLC files. MetalOS organizes them together in your game library and prepares the game automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 13) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 21)).foregroundStyle(studioAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("GAME TITLE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(dlcs.count) DLC").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }.padding(15).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            VStack(spacing: 8) {
                row(0, baseGame == nil ? "Choose base game" : "Base game selected", baseGame?.lastPathComponent ?? "Required · NSP, XCI, NSZ, XCZ or NUP", "square.stack.3d.up") { picker = .base }
                row(1, update == nil ? "Choose update" : "Update selected", update?.lastPathComponent ?? "Optional · choose the latest update file", "arrow.down.circle") { picker = .update }
                row(2, "Add DLC", dlcs.isEmpty ? "Optional · add each DLC file" : "\(dlcs.count) file\(dlcs.count == 1 ? "" : "s") selected", "plus.circle") { picker = .dlc }
                if !dlcs.isEmpty {
                    ForEach(Array(dlcs.enumerated()), id: \.element.path) { index, url in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(studioAccent)
                            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button { dlcs.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(url.lastPathComponent)")
                        }.padding(.horizontal, 12).frame(height: 28)
                    }
                }
                row(3, "Add to Games", "MetalOS creates the game folder and prepares the selected files", "plus.circle.fill", enabled: canAdd) {
                    requestAdd()
                }
                row(4, "Cancel", "Return to your games", "xmark") { onClose() }
            }
            Text("↑ ↓  Choose     A / ×  Select     B / ○  Back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(26).frame(width: 780, height: 650).background(studioBackground).preferredColorScheme(.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(ConsoleFeedback.shared.focusAnimation, value: selection)
            .consoleInput { command in
                switch command {
                case "up", "left": selection = max(selection - 1, 0)
                case "down", "right": selection = min(selection + 1, 4)
                case "confirm": activate()
                case "back", "menu", "context": onClose()
                default: break
                }
            }
            .consolePage(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
                if let picker {
                    let label = picker == .base ? "base game" : picker == .update ? "game update" : "DLC"
                    ConsoleFilePicker(title: "Choose \(label) file", mode: .file, allowedExtensions: SwitchGameDiscovery.extensions) { url in
                        switch picker {
                        case .base: baseGame = url
                        case .update: update = url
                        case .dlc: if !dlcs.contains(url) { dlcs.append(url) }
                        }
                        self.picker = nil
                    }
                }
            }
            .consolePage(isPresented: $showAddConfirmation) {
                ActionConfirmationView(title: "Add \(title)?", message: "MetalOS will copy the selected base game, update, and DLC into this game’s folder in your library.", confirmTitle: "Add game") {
                    guard let baseGame else { return }
                    store.importSwitch(baseGame: baseGame.path, update: update?.path, dlcs: dlcs.map(\.path))
                }
            }
    }
    private func row(_ index: Int, _ label: String, _ value: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        ConsoleActionRow(title: label, value: value, symbol: symbol, selected: selection == index, enabled: enabled) { selection = index; if enabled { action() } }
    }
    private func activate() {
        switch selection {
        case 0: picker = .base
        case 1: picker = .update
        case 2: picker = .dlc
        case 3:
            if canAdd { requestAdd() }
        default: onClose()
        }
    }
    private func requestAdd() { guard canAdd else { return }; showAddConfirmation = true }
}
struct BuildView: View {
    @EnvironmentObject var store: LibraryStore
    let gameID: String?
    let onClose: () -> Void
    var body: some View {
        BuildPanel(store: store, builder: store.builder, gameID: gameID, onClose: onClose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 66).padding(.top, 42).padding(.bottom, 24)
            .background {
                ZStack(alignment: .topTrailing) {
                    studioBackground
                    RadialGradient(colors: [studioAccent.opacity(0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 600)
                        .frame(width: 760, height: 520).allowsHitTesting(false)
                }.ignoresSafeArea()
            }
    }
}
struct BuildPanel: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var builder: NXBuildService
    @Environment(\.dismiss) private var dismiss
    let gameID: String?
    var onClose: (() -> Void)? = nil
    @State private var selection = 0
    @State private var showConfirmation = false
    @State private var confirmingStop = false
    @State private var logExpanded = false
    private var game: Game? { store.data.games.first { $0.id == gameID } }
    private var actions: [String] {
        if builder.isBuilding { return ["Stop build", logExpanded ? "Hide build log" : "Show build log", "Back to games"] }
        return [game?.launchURL.isEmpty == false ? "Rebuild game" : "Build & play", logExpanded ? "Hide build log" : "Show build log", "Back to games"]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BUILD STUDIO").font(.system(size: 9, weight: .bold)).tracking(2.6).foregroundStyle(studioAccent)
                    Text(builder.isBuilding ? "Preparing your game" : "Build your game").font(.system(size: 36, weight: .light))
                    Text(game?.title ?? "Choose a Switch game from the library").foregroundStyle(.secondary)
                }
                Spacer()
                Button { closePage() } label: {
                    Label("Back to games", systemImage: "arrow.left")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).frame(height: 40)
                        .background(.white.opacity(0.07), in: Capsule())
                }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Back to games")
            }
            if let game {
                HStack(spacing: 17) {
                    GameIcon(game: game).frame(width: 92, height: 92).clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GAME FILES").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(studioAccent)
                        HStack(spacing: 7) {
                            Circle().fill(game.isAvailable ? studioAccent : .orange).frame(width: 6, height: 6)
                            Text(game.isAvailable ? "Game files ready" : "Reconnect the game folder").font(.system(size: 12, weight: .medium))
                        }
                        Text(game.nxSupport?.label ?? "Checking NXNative compatibility…").font(.system(size: 11)).foregroundStyle(studioAccent)
                        if let support = game.nxSupport, !support.note.isEmpty { Text(support.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                }.padding(24).frame(minHeight: 166).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
            }
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Circle().fill(builder.isBuilding ? studioAccent : builder.status.localizedCaseInsensitiveContains("failed") ? .orange : .white.opacity(0.35)).frame(width: 7, height: 7)
                    Text(builder.isBuilding ? "BUILD IN PROGRESS" : "ENGINE STATUS").font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(builder.isBuilding ? studioAccent : .white.opacity(0.55))
                    Spacer()
                    if builder.isBuilding { Text(builder.elapsedLabel).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
                    if let progress = builder.progress { Text("\(Int(progress * 100))%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(studioAccent) }
                }
                if builder.isBuilding || builder.progress != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(builder.progressDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let progress = builder.progress { ProgressView(value: progress).tint(studioAccent) }
                        else { ProgressView().tint(studioAccent) }
                    }.accessibilityElement(children: .combine).accessibilityLabel("Build progress: \(builder.progressDetail)")
                } else {
                    Text(builder.status).font(.system(size: 20, weight: .light)).foregroundStyle(builder.status.contains("failed") || builder.status.contains("could not") ? .orange : .white.opacity(0.88))
                    Text("Your Switch files stay in this game’s folder while NXNative prepares the Mac build.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.48)).lineLimit(2)
                }
            }.padding(23).frame(maxWidth: .infinity, minHeight: 172, alignment: .leading)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            Text("ACTIONS").font(.system(size: 9, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.42))
            VStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, title in
                    ConsoleActionRow(title: title, value: index == 0 ? primaryActionSubtitle : index == 1 ? (logExpanded ? "Collapse live NXNative output" : "Expand live NXNative output") : "Builds continue in the background", symbol: index == 0 ? (builder.isBuilding ? "stop.circle" : "play.fill") : index == 1 ? (logExpanded ? "chevron.up.square" : "text.alignleft") : "arrow.uturn.backward", selected: selection == index) {
                        selection = index; activate()
                    }.id(index)
                }
            }
            if logExpanded { BuildLogPanel(builder: builder) }
            Spacer(minLength: 10)
            Text("↑ ↓  Choose     A / ×  Select     B / ○  Back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).preferredColorScheme(.dark)
            .animation(ConsoleFeedback.shared.focusAnimation, value: selection)
            .onChange(of: builder.isBuilding) { _, _ in selection = 0 }
            .consoleInput { command in
                switch command {
                case "up", "left": selection = max(selection - 1, 0)
                case "down", "right": selection = min(selection + 1, actions.count - 1)
                case "confirm": activate()
                case "back": closePage()
                case "menu", "context": break
                default: break
                }
            }
            .consolePage(isPresented: $showConfirmation) {
                ActionConfirmationView(
                    title: confirmingStop ? "Stop this build?" : "Build \(game?.title ?? "this game")?",
                    message: confirmingStop ? "NXNative will stop preparing this game. You can start the build again later." : "MetalOS will prepare this game with NXNative. Build files will stay in this game’s folder.",
                    confirmTitle: confirmingStop ? "Stop build" : "Build game",
                    destructive: confirmingStop
                ) {
                    if confirmingStop { builder.cancel() }
                    else if let gameID { store.startBuild(gameID: gameID, launchWhenComplete: game?.launchURL.isEmpty == true) }
                }
            }
    }
    private func closePage() {
        if let onClose { onClose() } else { dismiss() }
    }
    private var primaryActionSubtitle: String {
        if builder.isBuilding { return "Stop preparing this game" }
        if game?.launchURL.isEmpty == true { return "Build it once, then play from your library" }
        return "Apply the latest game profile and fixes"
    }
    private func activate() {
        switch selection {
        case 0:
            confirmingStop = builder.isBuilding
            showConfirmation = true
        case 1: logExpanded.toggle()
        default: closePage()
        }
    }
}
private struct BuildLogPanel: View {
    @ObservedObject var builder: NXBuildService
    private var lines: [String] { builder.log.components(separatedBy: .newlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE BUILD LOG").font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(studioAccent)
                Spacer()
                Text("\(lines.count) lines").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced)).id(index) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 210)
                .onChange(of: builder.log) { _, _ in if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
                .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}
