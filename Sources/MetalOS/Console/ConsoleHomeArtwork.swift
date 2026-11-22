import ImageIO
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
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func load(_ paths: [String], maxPixelSize: Int) async -> CGImage? {
        let load = Task.detached(priority: .userInitiated) { () -> CGImage? in
            for path in paths {
                guard !Task.isCancelled else { break }
                let url = URL(fileURLWithPath: path)
                let resources = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = resources?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let key = "\(maxPixelSize):\(modified):\(path)" as NSString
                if let cached = cache.object(forKey: key) { return cached }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                else { continue }
                cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                return image
            }
            return nil
        }
        return await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
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
