import SwiftUI

struct FullPageMessage: View {
    @Environment(\.consolePageClose) private var closePage
    let title: String
    let message: String
    var symbol = "info.circle"
    var buttonTitle = "Continue"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(studioAccent)
            Text(title).font(.system(size: 28, weight: .light)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.64)).multilineTextAlignment(.center)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560)
            Button(buttonTitle, action: closePage)
                .buttonStyle(.borderedProminent).tint(studioAccent).foregroundStyle(studioBackground)
                .keyboardShortcut(.defaultAction)
            Text("A / ×  Continue     B / ○  Back").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(studioBackground.ignoresSafeArea())
        .consoleInput { command in
            if command == "confirm" || command == "back" || command == "menu" { closePage() }
        }
    }
}
