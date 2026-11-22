import AppKit
import AVFoundation
import SwiftUI

struct WallpaperSettingsPage: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @State private var selectedAction = 0
    @State private var selectingMedia = false
    @State private var mediaKind: WallpaperMediaKind = .image

    private enum WallpaperMediaKind { case image, video }

    private var storedWallpaperPath: String? { store.data.settings.homeWallpaperPath }

    private var customWallpaperURL: URL? {
        guard let path = storedWallpaperPath,
              WallpaperPreset.fromStorageValue(path) == nil else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var selectedPreset: WallpaperPreset? {
        if storedWallpaperPath == nil { return .blueHorizon }
        return WallpaperPreset.fromStorageValue(storedWallpaperPath)
    }

    private var wallpaperImage: NSImage? {
        if let customWallpaperURL, !isVideo(customWallpaperURL), let image = NSImage(contentsOf: customWallpaperURL) { return image }
        guard let url = (selectedPreset ?? .blueHorizon).imageURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var customWallpaperIsVideo: Bool { customWallpaperURL.map(isVideo) ?? false }

    private var selectedWallpaperTitle: String {
        if let customWallpaperURL { return customWallpaperURL.lastPathComponent }
        return (selectedPreset ?? .blueHorizon).title
    }

    private var particlesBinding: Binding<Bool> {
        Binding(
            get: { store.data.settings.homeParticlesEnabled ?? true },
            set: { value in
                store.data.settings.homeParticlesEnabled = value
                store.save()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Back to settings")

                Image(systemName: "display")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text("Screen and Video")
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("HOME WALLPAPER")
                        .font(.system(size: 10, weight: .bold)).tracking(1.8)
                        .foregroundStyle(.white.opacity(0.54))

                    Group {
                        if customWallpaperIsVideo, let customWallpaperURL {
                            LoopingWallpaperVideo(url: customWallpaperURL)
                        } else if let wallpaperImage {
                            Image(nsImage: wallpaperImage)
                                .resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: [Color(red: 0.02, green: 0.08, blue: 0.22), appearance.accent.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                        }
                    }
                    .frame(maxWidth: 900).frame(height: 270).clipped()
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 8) {
                            Image(systemName: customWallpaperIsVideo ? "play.rectangle.fill" : "sparkles")
                            Text(selectedWallpaperTitle)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.13)))

                    HStack(spacing: 10) {
                        Button(action: chooseWallpaper) {
                            Label("Choose Image", systemImage: "photo.on.rectangle.angled")
                                .frame(minWidth: 150, minHeight: 42)
                        }
                        .buttonStyle(.borderedProminent).tint(appearance.accent)
                        .consoleFocus(selectedAction == 0, cornerRadius: 9, scale: 1.025)

                        Button(action: chooseVideo) {
                            Label("Choose Video", systemImage: "play.rectangle")
                                .frame(minWidth: 145, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .consoleFocus(selectedAction == 1, cornerRadius: 9, scale: 1.025)

                        Button(action: useDefaultWallpaper) {
                            Label("Use Default", systemImage: "arrow.uturn.backward")
                                .frame(minWidth: 130, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .consoleFocus(selectedAction == 2, cornerRadius: 9, scale: 1.025)
                        .disabled(customWallpaperURL == nil && selectedPreset == .blueHorizon)
                    }

                    Text("BUILT-IN WALLPAPERS")
                        .font(.system(size: 10, weight: .bold)).tracking(1.8)
                        .foregroundStyle(.white.opacity(0.54))
                        .padding(.top, 5)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(Array(WallpaperPreset.allCases.enumerated()), id: \.element) { item in
                            let index = item.offset
                            let preset = item.element
                            let selected = selectedPreset == preset
                            Button {
                                store.data.settings.homeWallpaperPath = preset.storageValue
                                store.save()
                            } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    if let url = preset.imageURL, let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image)
                                            .resizable().scaledToFill()
                                            .frame(maxWidth: .infinity).frame(height: 128).clipped()
                                    } else {
                                        Color.white.opacity(0.05).frame(height: 128)
                                    }
                                    HStack(spacing: 8) {
                                        Text(preset.title).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 0)
                                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(appearance.accent) }
                                    }
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.72))
                                    .padding(.horizontal, 11).padding(.bottom, 10)
                                }
                                .background(.white.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? appearance.accent.opacity(0.72) : .white.opacity(0.08), lineWidth: selected ? 1.5 : 1))
                            }
                            .buttonStyle(ConsoleButtonStyle())
                            .consoleFocus(selectedAction == index + 3, cornerRadius: 12, scale: 1.025)
                            .accessibilityLabel("Use \(preset.title) wallpaper")
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }

                    HStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(appearance.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ambient particles").font(.system(size: 14, weight: .medium))
                            Text("Slow drifting lights over the home screen")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                        }
                        Spacer()
                        Toggle("Ambient particles", isOn: particlesBinding)
                            .labelsHidden()
                            .tint(appearance.accent)
                            .consoleFocus(selectedAction == 7, cornerRadius: 8, scale: 1.02)
                    }
                    .padding(16)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedAction = 7 }

                    Text("Custom images and videos are copied into MetalOS storage. Videos play silently on a loop behind the home screen.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 36).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 34).padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .consoleInput(onCommand: navigate)
        .consolePage(isPresented: $selectingMedia) {
            ConsoleFilePicker(
                title: mediaKind == .image ? "Choose a Home Wallpaper" : "Choose a Home Video Wallpaper",
                mode: .file,
                allowedExtensions: mediaKind == .image
                    ? ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
                    : ["mov", "mp4", "m4v", "qt"],
                onSelect: importWallpaper
            )
        }
    }

    private func chooseWallpaper() {
        mediaKind = .image
        selectingMedia = true
    }

    private func chooseVideo() {
        mediaKind = .video
        selectingMedia = true
    }

    private func importWallpaper(_ source: URL) {
        store.importConsoleWallpaper(source)
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v", "qt"].contains(url.pathExtension.lowercased())
    }

    private func useDefaultWallpaper() {
        store.data.settings.homeWallpaperPath = nil
        store.save()
    }

    private func navigate(_ command: String) {
        switch command {
        case "up":
            if selectedAction == 7 { selectedAction = 5 }
            else if selectedAction >= 5 { selectedAction -= 2 }
            else if selectedAction >= 3 { selectedAction = 2 }
        case "down":
            if selectedAction <= 2 { selectedAction = 3 }
            else if selectedAction <= 4 { selectedAction += 2 }
            else if selectedAction == 6 { selectedAction = 7 }
        case "left":
            if selectedAction > 0 && selectedAction < 3 { selectedAction -= 1 }
            else if selectedAction == 4 { selectedAction = 3 }
            else if selectedAction == 6 { selectedAction = 5 }
        case "right":
            if selectedAction < 2 { selectedAction += 1 }
            else if selectedAction == 3 { selectedAction = 4 }
            else if selectedAction == 5 { selectedAction = 6 }
            else if selectedAction == 7 { particlesBinding.wrappedValue.toggle() }
        case "confirm":
            if selectedAction == 0 { chooseWallpaper() }
            else if selectedAction == 1 { chooseVideo() }
            else if selectedAction == 2 { useDefaultWallpaper() }
            else if selectedAction <= 6 {
                let preset = WallpaperPreset.allCases[selectedAction - 3]
                store.data.settings.homeWallpaperPath = preset.storageValue
                store.save()
            } else { particlesBinding.wrappedValue.toggle() }
        case "back": dismiss()
        default: break
        }
    }
}

@MainActor
private final class WallpaperLoopPlayer: ObservableObject {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: item)
    }
}

struct LoopingWallpaperVideo: View {
    @StateObject private var playback: WallpaperLoopPlayer

    init(url: URL) {
        _playback = StateObject(wrappedValue: WallpaperLoopPlayer(url: url))
    }

    var body: some View {
        WallpaperPlayerLayer(player: playback.player)
            .onAppear { playback.player.play() }
            .onDisappear { playback.player.pause() }
            .accessibilityHidden(true)
    }
}

private struct WallpaperPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

@MainActor
extension LibraryStore {
    func importConsoleWallpaper(_ source: URL) {
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MetalOS/Wallpapers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let destination = folder.appendingPathComponent("home-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)
            data.settings.homeWallpaperPath = destination.path
            save()
        } catch {
            notice = "Could not save the wallpaper: \(error.localizedDescription)"
        }
    }
}
