import AVFoundation
import AppKit
import SwiftUI

struct StartupScreenView: View {
    let onFinished: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StartupVideoPlayer(onFinished: onFinished)
                .ignoresSafeArea()
            Button("Skip intro", action: onFinished)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.black.opacity(0.38), in: Capsule())
                .padding(28)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .consoleInput { command in
            if command == "confirm" || command == "back" { onFinished() }
        }
    }
}

private struct StartupVideoPlayer: NSViewRepresentable {
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(videoURL: Bundle.module.url(forResource: "metalos_startup", withExtension: "mp4"),
                    onFinished: onFinished)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = AVPlayerLayer()

        guard let playerLayer = view.layer as? AVPlayerLayer else {
            context.coordinator.onFinished()
            return view
        }
        playerLayer.player = context.coordinator.player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        context.coordinator.player?.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let onFinished: () -> Void
        let player: AVPlayer?
        private var endObserver: NSObjectProtocol?

        init(videoURL: URL?, onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
            if let videoURL {
                let item = AVPlayerItem(url: videoURL)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                self.player = player
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    self?.onFinished()
                }
            } else {
                player = nil
                DispatchQueue.main.async { onFinished() }
            }
        }

        func stop() {
            player?.pause()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }
    }
}
