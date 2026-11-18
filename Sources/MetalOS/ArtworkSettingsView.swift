import SwiftUI
import AppKit

struct ArtworkSettingsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var credentials: ArtworkCredentialStore
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Game artwork and details").font(.title2.bold())
            Text("MetalOS automatically looks up artwork, descriptions, and screenshots when games are added or discovered in your library.").foregroundStyle(.secondary)
            if store.isFetchingArtwork { ProgressView().controlSize(.small) }
            Text(store.artworkStatus).font(.callout).foregroundStyle(studioAccent)
            Text("Artwork is stored with your library data and remains available if a lookup cannot find a match.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(24)
        }
    }
}
struct GameArtworkView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let gameID: String
    private var game: Game? { store.data.games.first { $0.id == gameID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Game Art & Details").font(.title.bold())
                    Text(game?.title ?? "Game no longer in library").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let game {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 22) {
                            artworkPreview(game.boxArt, label: "COVER ART", ratio: 2.0 / 3.0).frame(width: 120)
                            artworkPreview(game.heroArt, label: "BACKGROUND ART", ratio: 16.0 / 9.0).frame(maxWidth: .infinity)
                        }.frame(height: 215, alignment: .top)
                        if game.source == .nxnative, let path = game.artworkPath, let icon = NSImage(contentsOfFile: path) {
                            HStack(spacing: 12) {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("GAME ICON").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                                    Text("Extracted from the game files").font(.caption).foregroundStyle(.white.opacity(0.72))
                                }
                                Spacer()
                            }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if let metadata = game.metadata {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ABOUT THIS GAME").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(studioAccent)
                                if let summary = metadata.summary ?? metadata.storyline {
                                    Text(summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                }
                                let facts = [metadata.genres.joined(separator: ", "), metadata.platforms.joined(separator: ", "), metadata.developers.joined(separator: ", ")].filter { !$0.isEmpty }
                                if !facts.isEmpty { Text(facts.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary) }
                                if !metadata.screenshots.isEmpty {
                                    Text("SCREENSHOTS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary).padding(.top, 3)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            ForEach(metadata.screenshots, id: \.path) { shot in
                                                if let image = NSImage(contentsOfFile: shot.path) {
                                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 210, height: 118)
                                                        .clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                                                }
                                            }
                                        }
                                    }
                                }
                            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            HStack(spacing: 10) {
                                if store.isFetchingArtwork { ProgressView().controlSize(.small) }
                                Text(store.isFetchingArtwork ? "Finding artwork and game details…" : "Game details will appear here when available.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let match = game.artworkMatchedTitle { Text("Matched game: \(match)").font(.caption).foregroundStyle(.secondary) }
                        if let message = store.artworkMessages[game.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack { if store.isFetchingArtwork { ProgressView().controlSize(.small) }; Text(store.artworkStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Text("B / ○  Back").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(28).frame(width: 720, height: 620).background(studioBackground).preferredColorScheme(.dark)
        .onAppear { store.fetchArtwork(gameID: gameID) }
        .consoleInput(onCommand: { command in if command == "back" || command == "menu" || command == "context" { dismiss() } })
    }
    private func artworkPreview(_ record: ArtworkRecord?, label: String, ratio: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05))
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        Group {
                            if let record, let image = NSImage(contentsOfFile: record.path) { Image(nsImage: image).resizable().scaledToFit() }
                            else { Image(systemName: "photo").font(.title).foregroundStyle(.tertiary) }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            if let record { Text(record.credit ?? record.provider).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}
