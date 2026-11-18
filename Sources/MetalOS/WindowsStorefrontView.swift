import SwiftUI
import AppKit

struct WindowsStorefrontView: View {
    @ObservedObject var runtime: WindowsStorefrontRuntime
    @ObservedObject var windowsClientInstaller: WindowsClientInstaller
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var signInURL: URL?
    @State private var signInProvider: WindowsStorefront = .epic
    @State private var focusZone = 0
    @State private var focusIndex = 0
    @State private var gameIndex = 0
    private var games: [WindowsStoreGame] { runtime.selectedProvider == .epic ? runtime.epicGames : runtime.gogGames }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(runtime.selectedProvider.rawValue).font(.system(size: 26, weight: .light))
                    Text(runtime.selectedProvider == .epic
                         ? "Legendary manages Epic sign-in, installs, updates, and launch."
                         : "gogdl manages GOG sign-in, downloads, saves, and launch.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(Array(WindowsStorefront.allCases.enumerated()), id: \.element.id) { index, provider in
                        Button(provider.rawValue) { focusIndex = index; runtime.selectedProvider = provider }
                            .buttonStyle(ConsoleButtonStyle())
                            .foregroundStyle(runtime.selectedProvider == provider ? .white : .white.opacity(0.58))
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(runtime.selectedProvider == provider ? studioAccent.opacity(0.7) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .consoleFocus(focusZone == 0 && focusIndex == index, cornerRadius: 7)
                    }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).frame(width: 32, height: 32)
                        .background(.white.opacity(0.06), in: Circle())
                }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close store library")
                    .consoleFocus(focusZone == 0 && focusIndex == 2, cornerRadius: 16)
            }

            HStack(spacing: 10) {
                Button(runtime.selectedProvider == .epic ? "Install Legendary" : "Install gogdl") {
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.installLegendary(workspace: store.workspaceURL) }
                        else { await runtime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
                    }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking || store.workspaceURL == nil)
                    .consoleFocus(focusZone == 1 && focusIndex == 0, cornerRadius: 8)

                Button("Sign in") {
                    signInProvider = runtime.selectedProvider
                    if signInProvider == .epic { signInURL = runtime.epicLoginURL(workspace: store.workspaceURL) }
                    else { signInURL = runtime.gogLoginURL() }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking)
                    .consoleFocus(focusZone == 1 && focusIndex == 1, cornerRadius: 8)

                Button("Refresh library") {
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.refreshEpicGames(workspace: store.workspaceURL) }
                        else { await runtime.refreshGOGGames(workspace: store.workspaceURL) }
                    }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking)
                    .consoleFocus(focusZone == 1 && focusIndex == 2, cornerRadius: 8)
            }

            if runtime.isWorking { ProgressView().tint(studioAccent) }
            Text(runtime.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58)).textSelection(.enabled)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                            HStack(spacing: 12) {
                                Image(systemName: runtime.selectedProvider == .epic ? "e.square.fill" : "g.square.fill")
                                    .font(.system(size: 18)).foregroundStyle(studioAccent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(game.title).font(.system(size: 13, weight: .medium))
                                    Text(game.isInstalled ? (game.installedPath ?? "Installed") : "Ready to install")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button(game.isInstalled ? "Installed" : "Install") {
                                    Task {
                                        let provider = runtime.selectedProvider
                                        await runtime.install(game, provider: provider, workspace: store.workspaceURL, wineInstaller: windowsClientInstaller)
                                        await store.scan()
                                    }
                                }.buttonStyle(ConsoleButtonStyle()).disabled(game.isInstalled || runtime.isWorking || store.workspaceURL == nil)
                                    .consoleFocus(focusZone == 2 && gameIndex == index, cornerRadius: 7)
                            }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focusZone == 2 && gameIndex == index ? studioAccent.opacity(0.6) : .clear))
                                .id(index)
                        }
                        if games.isEmpty {
                            Text("Install the store tool, sign in, then refresh to show games from your account.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(24)
                        }
                    }
                }
                .onChange(of: gameIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .frame(minHeight: 180)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 500)
        .preferredColorScheme(.dark)
        .consoleInput(onCommand: navigate)
        .onAppear { focusIndex = WindowsStorefront.allCases.firstIndex(of: runtime.selectedProvider) ?? 0 }
        .onChange(of: runtime.selectedProvider) { _, _ in gameIndex = 0 }
        .sheet(isPresented: Binding(get: { signInURL != nil }, set: { if !$0 { signInURL = nil } })) {
            if let url = signInURL {
                StoreSignInBrowser(title: "Sign in to \(signInProvider.rawValue)", url: url) { code in
                    Task {
                        if signInProvider == .epic { await runtime.completeEpicLogin(code: code, workspace: store.workspaceURL) }
                        else { await runtime.completeGOGLogin(code: code, workspace: store.workspaceURL) }
                        await store.scan()
                    }
                }
            }
        }
    }

    private func navigate(_ command: String) {
        switch command {
        case "left", "right":
            let delta = command == "left" ? -1 : 1
            if focusZone == 0 { focusIndex = min(max(focusIndex + delta, 0), 2) }
            else if focusZone == 1 { focusIndex = min(max(focusIndex + delta, 0), 2) }
        case "up":
            if focusZone == 2 && gameIndex > 0 { gameIndex -= 1 }
            else if focusZone > 0 {
                focusZone -= 1
                focusIndex = focusZone == 0 ? (WindowsStorefront.allCases.firstIndex(of: runtime.selectedProvider) ?? 0) : 0
            }
            else { dismiss() }
        case "down":
            if focusZone == 0 { focusZone = 1; focusIndex = 0 }
            else if focusZone == 1 && !games.isEmpty { focusZone = 2; gameIndex = 0 }
            else { gameIndex = min(gameIndex + 1, max(games.count - 1, 0)) }
        case "back", "menu", "context": dismiss()
        case "confirm":
            if focusZone == 0 {
                if focusIndex < WindowsStorefront.allCases.count { runtime.selectedProvider = WindowsStorefront.allCases[focusIndex] }
                else { dismiss() }
            } else if focusZone == 1 {
                switch focusIndex {
                case 0:
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.installLegendary(workspace: store.workspaceURL) }
                        else { await runtime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
                    }
                case 1:
                    signInProvider = runtime.selectedProvider
                    signInURL = signInProvider == .epic ? runtime.epicLoginURL(workspace: store.workspaceURL) : runtime.gogLoginURL()
                default:
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.refreshEpicGames(workspace: store.workspaceURL) }
                        else { await runtime.refreshGOGGames(workspace: store.workspaceURL) }
                    }
                }
            } else if games.indices.contains(gameIndex), !games[gameIndex].isInstalled, !runtime.isWorking, store.workspaceURL != nil {
                let game = games[gameIndex]
                Task {
                    await runtime.install(game, provider: runtime.selectedProvider, workspace: store.workspaceURL, wineInstaller: windowsClientInstaller)
                    await store.scan()
                }
            }
        case "previous", "next":
            runtime.selectedProvider = command == "previous" ? .epic : .gog
            focusIndex = WindowsStorefront.allCases.firstIndex(of: runtime.selectedProvider) ?? 0
        default: break
        }
    }
}
