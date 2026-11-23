import SwiftUI

struct ConsoleHomeArtwork: View {
    let paths: [String]
    let maxPixelSize: Int
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
        .task(id: paths) {
            image = nil
            guard !paths.isEmpty else { return }
            let loaded = await ConsoleArtworkImages.load(paths, maxPixelSize: maxPixelSize)
            if !Task.isCancelled { image = loaded }
        }
    }
}

private enum ConsoleArtworkImages {
    static func load(_ paths: [String], maxPixelSize: Int) async -> CGImage? {
        for path in paths {
            guard !Task.isCancelled else { return nil }
            if let image = await GameArtworkImageCache.shared.image(path: path, maxPixelSize: maxPixelSize) {
                return image
            }
        }
        return nil
    }
}

struct ConsoleHomeBackdrop: View {
    let paths: [String]
    let video: URL?
    let accent: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var feedback = ConsoleFeedback.shared
    @ObservedObject private var preferences = ConsolePreferences.shared

    var body: some View {
        ZStack {
            ConsoleDesign.Palette.canvas
            if !reduceTransparency, preferences.ambient != .off {
                Group {
                    if let video, !feedback.motionReduced {
                        LoopingWallpaperVideo(url: video).id(video)
                    } else {
                        ConsoleHomeArtwork(paths: paths, maxPixelSize: 800).id(paths)
                    }
                }
                    .scaleEffect(1.14)
                    .blur(radius: ConsoleDesign.Artwork.blurRadius, opaque: true)
                    .saturation(0.72)
                    .opacity(preferences.ambient.intensity)
                    .transition(.opacity)
            }
            Rectangle().fill(ConsoleDesign.Palette.canvas.opacity(ConsoleDesign.Artwork.scrimOpacity))
            RadialGradient(colors: [accent.opacity(preferences.ambient.intensity * 0.2), .clear], center: .trailing,
                           startRadius: 40, endRadius: 720)
            LinearGradient(colors: [.clear, ConsoleDesign.Palette.canvas.opacity(0.92)],
                           startPoint: .center, endPoint: .bottom)
        }
        .clipped()
        .animation(feedback.pageAnimation, value: paths)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
