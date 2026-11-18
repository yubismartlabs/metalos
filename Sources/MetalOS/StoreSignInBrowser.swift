import SwiftUI

struct StoreSignInBrowser: View {
    let title: String
    let url: URL
    let complete: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = InAppBrowserSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(13)
            InAppBrowserView(session: session, authorizationCompletion: { code in complete(code); dismiss() },
                             close: { dismiss() }, closeTitle: "Close")
        }
        .onAppear { session.loadAddress(url.absoluteString) }
        .frame(minWidth: 760, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}
