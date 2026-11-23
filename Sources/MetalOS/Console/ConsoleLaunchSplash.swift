import SwiftUI

struct ConsoleLaunchSplash: View {
    let game: Game
    @State private var pulse = false

    private var artworkPaths: [String] {
        [game.customArtworkPath, game.heroArt?.path, game.boxArt?.path, game.artworkPath].compactMap { $0 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.black
                ConsoleHomeArtwork(paths: artworkPaths, maxPixelSize: 2400)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.9)
                LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.46), .black.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(game.platformBadge ?? game.source.rawValue.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2.4)
                            .foregroundStyle(.white.opacity(0.72))
                        Text(game.displayTitle)
                            .font(.system(size: min(geometry.size.width * 0.055, 66), weight: .medium, design: .rounded))
                            .tracking(-1.8).lineLimit(1).minimumScaleFactor(0.72)
                        HStack(spacing: 13) {
                            ProgressView().controlSize(.regular).tint(.white)
                            Text("Starting game")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.74))
                        }
                        .opacity(pulse ? 1 : 0.56)
                    }
                    Spacer()
                    Text("METALOS")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).tracking(3.2)
                        .foregroundStyle(.white.opacity(0.46))
                }
                .padding(.horizontal, max(48, geometry.size.width * 0.052))
                .padding(.bottom, max(42, geometry.size.height * 0.08))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .task {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting \(game.displayTitle)")
    }
}
