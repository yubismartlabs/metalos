import SwiftUI
import WebKit

struct ConsoleOverviewOverlay: View {
    let modal: ConsoleOverviewModal
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            switch modal {
            case .trailer(let video):
                VStack(spacing: 22) {
                    ConsoleYouTubePlayer(videoID: video.videoID)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: 1320, maxHeight: 744)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(video.title).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                }
                .padding(50)
            case .screenshot(let title, let paths, let index):
                ZStack(alignment: .bottom) {
                    if paths.indices.contains(index) {
                        ConsoleHomeArtwork(paths: [paths[index]], maxPixelSize: 3200)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 54)
                            .padding(.vertical, 82)
                    }
                    HStack {
                        Text(title).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(index + 1) / \(max(1, paths.count))")
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 58).padding(.bottom, 34)
                }
            case .summary(let title, let summary, let storyline):
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(title).font(.system(size: 30, weight: .medium, design: .rounded))
                        Spacer()
                        Image(systemName: "text.alignleft").font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.6))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Text(summary).font(.system(size: 21, weight: .regular)).lineSpacing(8)
                            if let storyline, !storyline.isEmpty {
                                Text(storyline).font(.system(size: 18, weight: .regular)).lineSpacing(7).foregroundStyle(.white.opacity(0.77))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold))
                        Text("Back to Game Hub").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.64))
                }
                .padding(36)
                .frame(maxWidth: 1040, maxHeight: 690)
                .background(.ultraThinMaterial.opacity(0.78), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 35, y: 16)
                .padding(54)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            Text("Back").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 15).frame(height: 40)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(38)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

private struct ConsoleYouTubePlayer: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(Self.html(videoID: videoID), baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        webView.loadHTMLString(Self.html(videoID: videoID), baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    private static func html(videoID: String) -> String {
        guard videoID.range(of: #"^[A-Za-z0-9_-]{6,32}$"#, options: .regularExpression) != nil else { return "<html><body style='background:#000'></body></html>" }
        return """
        <!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}::-webkit-scrollbar{display:none}</style></head>
        <body style='margin:0;background:#000;overflow:hidden'><iframe src='https://www.youtube-nocookie.com/embed/\(videoID)?autoplay=1&controls=0&playsinline=1&rel=0' style='position:fixed;inset:0;width:100%;height:100%;border:0' allow='autoplay; encrypted-media; picture-in-picture' allowfullscreen></iframe></body></html>
        """
    }
}
