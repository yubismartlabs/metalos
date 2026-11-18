import SwiftUI
import AppKit

struct WindowsStorefrontView: View {
    @ObservedObject var runtime: WindowsStorefrontRuntime
    @ObservedObject var windowsClientInstaller: WindowsClientInstaller
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var signInURL: URL?
    @State private var signInProvider: WindowsStorefront = .epic

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
                Picker("Store", selection: $runtime.selectedProvider) {
                    ForEach(WindowsStorefront.allCases) { provider in Text(provider.rawValue).tag(provider) }
                }.pickerStyle(.segmented).frame(width: 230)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).frame(width: 32, height: 32)
                        .background(.white.opacity(0.06), in: Circle())
                }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close store library")
            }

            HStack(spacing: 10) {
                Button(runtime.selectedProvider == .epic ? "Install Legendary" : "Install gogdl") {
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.installLegendary(workspace: store.workspaceURL) }
                        else { await runtime.installGogdl(workspace: store.workspaceURL, pythonPath: store.data.settings.pythonPath) }
                    }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking || store.workspaceURL == nil)

                Button("Sign in") {
                    signInProvider = runtime.selectedProvider
                    if signInProvider == .epic { signInURL = runtime.epicLoginURL(workspace: store.workspaceURL) }
                    else { signInURL = runtime.gogLoginURL() }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking)

                Button("Refresh library") {
                    Task {
                        if runtime.selectedProvider == .epic { await runtime.refreshEpicGames(workspace: store.workspaceURL) }
                        else { await runtime.refreshGOGGames(workspace: store.workspaceURL) }
                    }
                }.buttonStyle(ConsoleButtonStyle()).disabled(runtime.isWorking)
            }

            if runtime.isWorking { ProgressView().tint(studioAccent) }
            Text(runtime.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58)).textSelection(.enabled)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(runtime.selectedProvider == .epic ? runtime.epicGames : runtime.gogGames) { game in
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
                        }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if (runtime.selectedProvider == .epic ? runtime.epicGames : runtime.gogGames).isEmpty {
                        Text("Install the store tool, sign in, then refresh to show games from your account.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(24)
                    }
                }
            }
            .frame(minHeight: 180)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 500)
        .preferredColorScheme(.dark)
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
}
