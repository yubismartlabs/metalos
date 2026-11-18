import SwiftUI
import AppKit

enum GameDetailAction: String, CaseIterable, Identifiable {
    case play, favorite, artwork, build, bottleTools, reveal
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .favorite: "heart"
        case .artwork: "photo"
        case .build: "hammer"
        case .bottleTools: "shippingbox"
        case .reveal: "folder"
        }
    }
    func title(for game: Game) -> String {
        switch self {
        case .play: "Play game"
        case .favorite: game.favorite ? "Unfavorite" : "Favorite"
        case .artwork: "Refresh game details"
        case .build: "Build studio"
        case .bottleTools: "Game bottle"
        case .reveal: "Files"
        }
    }
}
struct GameDetailsView: View {
    @EnvironmentObject var store: LibraryStore
    let gameID: String
    @Binding var selectedAction: Int
    @Binding var scrollTarget: Int
    let onClose: () -> Void
    let onAction: (GameDetailAction) -> Void
    @State private var showBottleTools = false
    private var game: Game? { store.data.games.first { $0.id == gameID } }
    static func actions(for game: Game) -> [GameDetailAction] {
        GameDetailAction.allCases.filter {
            ($0 != .build || game.source == .nxnative)
                && ($0 != .bottleTools || game.windowsExecutablePath != nil || (game.windowsStoreProvider != nil && game.isAvailable))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let game {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(studioBackground)
                    if let path = game.heroArt?.path, let hero = NSImage(contentsOfFile: path) {
                        GeometryReader { geometry in
                            Image(nsImage: hero).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    } else {
                        LinearGradient(colors: [studioAccent.opacity(0.18), studioBackground], startPoint: .topTrailing, endPoint: .bottomLeading)
                    }
                    LinearGradient(colors: [.clear, studioBackground], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 12) {
                        Label(game.source.rawValue.uppercased(), systemImage: game.source.symbol)
                            .font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(studioAccent)
                        Text(game.title).font(.system(size: 37, weight: .light)).tracking(-1).lineLimit(2)
                        HStack(spacing: 10) {
                            Button { onAction(.play) } label: {
                                Label("Play game", systemImage: "play.fill")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 20).frame(height: 40).background(studioAccent, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(ConsoleButtonStyle()).disabled(!game.isAvailable)
                            Button { onAction(.favorite) } label: {
                                Image(systemName: game.favorite ? "heart.fill" : "heart")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(game.favorite ? studioAccent : .white)
                                    .frame(width: 40, height: 40).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel(game.favorite ? "Remove favorite" : "Add favorite")
                        }
                    }.padding(28)
                }.frame(height: 260).clipped()
                    .overlay(alignment: .topTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).padding(11).background(.black.opacity(0.5), in: Circle())
                        }.buttonStyle(ConsoleButtonStyle()).keyboardShortcut(.cancelAction).help("Back to games").padding(20)
                    }
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 25) {
                            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04))
                                .frame(width: 130, height: 195)
                                .overlay { GameIcon(game: game).padding(game.boxArt == nil ? 16 : 0) }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
                            VStack(alignment: .leading, spacing: 15) {
                                HStack(spacing: 9) {
                                    Circle().fill(game.isAvailable ? studioAccent : .orange).frame(width: 6, height: 6)
                                    Text(game.isAvailable ? (game.launchURL.isEmpty ? "Ready to build" : "Built · Ready to play") : "Drive offline")
                                        .font(.system(size: 13, weight: .medium))
                                    if game.favorite { Image(systemName: "heart.fill").foregroundStyle(studioAccent) }
                                }
                                HStack(spacing: 36) {
                                    detail("LIBRARY", game.source.rawValue)
                                    detail("LAST PLAYED", game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not played yet")
                                }
                                detail("LOCATION", game.installPath)
                                if game.windowsStoreProvider != nil {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("WINDOWS RUNTIME").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.35))
                                        Picker("Windows runtime", selection: Binding(
                                            get: { game.windowsCompatibilityRuntime ?? .managedWine },
                                            set: { store.setWindowsCompatibilityRuntime($0, for: game.id) }
                                        )) {
                                            ForEach(WindowsCompatibilityRuntime.allCases) { runtime in
                                                Text(runtime.title).tag(runtime)
                                            }
                                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 370, alignment: .leading)
                                        Text((game.windowsCompatibilityRuntime ?? .managedWine).detail)
                                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).fixedSize(horizontal: false, vertical: true)
                                        if game.windowsCompatibilityRuntime != .gamePortingToolkit {
                                            Text("DIRECTX GRAPHICS").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.35)).padding(.top, 6)
                                        Picker("Graphics backend", selection: Binding(
                                            get: { game.windowsGraphicsBackendUserSet == true ? (game.windowsGraphicsBackend ?? .automatic) : .automatic },
                                            set: { store.setWindowsGraphicsBackend($0, for: game.id) }
                                        )) {
                                            ForEach(WindowsGraphicsBackend.allCases) { backend in
                                                Text(backend.title).tag(backend)
                                            }
                                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 370, alignment: .leading)
                                        Text((game.windowsGraphicsBackendUserSet == true ? (game.windowsGraphicsBackend ?? .automatic) : .automatic).detail)
                                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .accessibilityElement(children: .contain)
                                }
                                if let titleID = game.titleID { detail("TITLE ID", titleID) }
                                if game.source == .nxnative {
                                    detail("NXNATIVE SUPPORT", game.nxSupport?.label ?? "Not checked yet")
                                    if let support = game.nxSupport {
                                        Text(support.note).font(.caption).foregroundStyle(.secondary)
                                        if let link = support.notesURL, let url = URL(string: link) {
                                            Link("Official NXNative game notes", destination: url).font(.caption)
                                        }
                                    }
                                    if let input = game.buildInput { detail("GAME / WORKING FOLDER", input) }
                                }
                                if game.source == .nxnative, let path = game.forkPath ?? (store.data.settings.forkPath.isEmpty ? nil : store.data.settings.forkPath) {
                                    detail("NXNATIVE CHECKOUT", path)
                                }
                                if let matched = game.artworkMatchedTitle { detail("ARTWORK MATCH", matched) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.horizontal, 28).padding(.top, 5).id("detail-top")
                        if let metadata = game.metadata {
                            metadataPanel(metadata)
                                .padding(.horizontal, 28).padding(.bottom, 18).id("detail-metadata")
                            if let message = store.artworkMessages[game.id] {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).padding(.horizontal, 28).padding(.bottom, 18)
                            }
                        } else {
                            Text(store.artworkMessages[game.id] ?? "MetalOS will add available artwork and game details automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 28).padding(.bottom, 18)
                        }
                    }
                }.frame(maxHeight: .infinity)
                    .onChange(of: scrollTarget) { _, target in
                        withAnimation(ConsoleFeedback.shared.focusAnimation) {
                            proxy.scrollTo(target == 0 ? "detail-top" : "detail-metadata", anchor: .top)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(Self.actions(for: game).enumerated()), id: \.element.id) { index, action in
                        Button {
                            selectedAction = index
                            if action == .bottleTools { showBottleTools = true } else { onAction(action) }
                        } label: {
                            VStack(spacing: 9) {
                                Image(systemName: action == .favorite && game.favorite ? "heart.fill" : action.symbol).font(.system(size: 17))
                                Text(action.title(for: game)).font(.system(size: 11, weight: .semibold))
                            }.frame(maxWidth: .infinity).frame(height: 72)
                                .foregroundStyle(selectedAction == index ? studioBackground : .white.opacity(0.8))
                                .background(selectedAction == index ? studioAccent : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selectedAction == index, cornerRadius: 12, scale: 1.055)
                            .accessibilityAddTraits(selectedAction == index ? [.isSelected] : [])
                    }
                }.padding(.horizontal, 28)
                HStack(spacing: 20) {
                    Text("← →  Select")
                    Text("A  Confirm")
                    Text("B  Back")
                    Spacer()
                    Text("OPTIONS  Game menu")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(28)
            } else {
                ContentUnavailableView("Game not in library", systemImage: "gamecontroller", description: Text("Return to your collection to choose another game."))
                Button("Back", action: onClose).padding()
            }
        }.animation(ConsoleFeedback.shared.focusAnimation, value: selectedAction).consoleMotion().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(studioBackground).preferredColorScheme(.dark).tint(studioAccent)
            .consoleSheet(isPresented: $showBottleTools) {
                if let game, let workspace = store.workspaceURL {
                    WindowsBottleToolsView(game: game, workspace: workspace, onClose: { showBottleTools = false })
                } else {
                    ContentUnavailableView("Bottle unavailable", systemImage: "shippingbox", description: Text("Set a library folder and make sure this Windows game has been installed."))
                }
            }
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.35))
            Text(value).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
    @ViewBuilder
    private func metadataPanel(_ metadata: GameMetadata) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("GAME DETAILS").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(studioAccent)
                Spacer()
                if let raw = metadata.sourceURL, let url = URL(string: raw), url.scheme == "https" {
                    Link("GameDB / IGDB source ↗", destination: url).font(.caption)
                }
            }
            if let description = metadata.summary ?? metadata.storyline {
                Text(description).font(.system(size: 13)).foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            let facts: [(String, [String])] = [
                ("GENRES", metadata.genres), ("PLATFORMS", metadata.platforms),
                ("DEVELOPER", metadata.developers), ("PUBLISHER", metadata.publishers)
            ].filter { !$0.1.isEmpty }
            if !facts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 14) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in detail(fact.0, fact.1.joined(separator: ", ")) }
                    if let date = metadata.releaseDate { detail("RELEASED", date) }
                }
            } else if let date = metadata.releaseDate {
                detail("RELEASED", date)
            }
            if !metadata.screenshots.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("SCREENSHOTS · \(metadata.screenshots.count)").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(metadata.screenshots.enumerated()), id: \.element.path) { index, shot in
                                if let image = NSImage(contentsOfFile: shot.path) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(width: 205, height: 116).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .overlay(alignment: .bottomTrailing) {
                                            Text(String(format: "%02d", index + 1)).font(.system(size: 9, weight: .bold)).padding(5)
                                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)).padding(6)
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.07)))
    }
}
