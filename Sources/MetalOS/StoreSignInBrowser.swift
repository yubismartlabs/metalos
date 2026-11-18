import SwiftUI
import AppKit

private enum StoreSignInMode: Equatable {
    case internalBrowser
    case externalBrowser
}

struct StoreSignInBrowser: View {
    let title: String
    let url: URL
    @ObservedObject var session: InAppBrowserSession
    let complete: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller = ControllerManager.shared
    @State private var mode: StoreSignInMode?
    @State private var modeSelection = 0
    @State private var externalAction = 0
    @State private var code = ""
    @State private var keyboardOpen = false

    var body: some View {
        Group {
            switch mode {
            case .internalBrowser:
                VStack(spacing: 0) {
                    signInHeader(backLabel: "Sign-in options")
                    InAppBrowserView(session: session, authorizationCompletion: finish, close: { mode = nil }, closeTitle: "Back")
                }
            case .externalBrowser:
                externalBrowserEntry
            case nil:
                modePicker
            }
        }
        .onAppear {
            session.onAuthorizationCodeDetected = { detectedCode in finish(detectedCode) }
            syncBackgroundControllerAction()
        }
        .onChange(of: mode) { _, _ in syncBackgroundControllerAction() }
        .onChange(of: session.externalAuthenticationMessage) { _, _ in syncBackgroundControllerAction() }
        .onDisappear {
            session.onAuthorizationCodeDetected = nil
            controller.inactiveAppAction = nil
        }
        .frame(minWidth: 760, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(studioAccent)
        .consoleSheet(isPresented: $keyboardOpen) {
            SearchKeyboardView(query: $code, title: "Enter authorization code", subtitle: "Enter the code or redirect URL shown in your browser.", doneTitle: "Connect", onCancel: { keyboardOpen = false }) {
                keyboardOpen = false
                finish(code)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 22) {
            signInHeader(backLabel: "Cancel")
            Text("Choose where to sign in").font(.system(size: 28, weight: .light))
            Text("Use the internal browser to share your Epic or GOG sign-in with its store website. Google blocks OAuth inside embedded browsers. If a Steam or other provider login does not finish internally, use the default browser instead; external-browser cookies cannot be shared with the store website.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                modeButton("Internal browser", detail: "Stay inside MetalOS", index: 0)
                modeButton("Default browser", detail: "Recommended for Google or Steam sign-in", index: 1)
                modeButton("Cancel", detail: "Return to the store library", index: 2)
            }
            Spacer(minLength: 0)
            Text("↑ ↓  Choose     A  Select     B  Cancel")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBackground)
        .consoleInput { command in
            switch command {
            case "up", "left": modeSelection = max(modeSelection - 1, 0)
            case "down", "right": modeSelection = min(modeSelection + 1, 2)
            case "confirm": selectMode(modeSelection)
            case "back", "menu", "context": dismiss()
            default: break
            }
        }
    }

    private var externalBrowserEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            signInHeader(backLabel: "Sign-in options")
            Text("Finish signing in in your default browser")
                .font(.system(size: 26, weight: .light))
            Text("When the provider returns a code or redirect URL, copy it, return to MetalOS, then paste it here. MetalOS uses that value to finish signing in with \(title). Never enter your account password in this screen.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
            TextField("Authorization code or redirect URL", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                .consoleFocus(externalAction == 2, cornerRadius: 7)
            VStack(spacing: 8) {
                externalButton("Open browser again", index: 0) { openExternalBrowser() }
                externalButton("Paste from clipboard", index: 1) { pasteCode() }
                externalButton("Enter code with virtual keyboard", index: 2) { keyboardOpen = true }
                externalButton("Connect", index: 3) { finish(code) }
                externalButton("Back to sign-in options", index: 4) { mode = nil }
            }
            Spacer(minLength: 0)
            HStack {
                Text("↑ ↓  Choose")
                Text("A  Select")
                Text("B  Back")
                Spacer()
                Text("\(title)").lineLimit(1)
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBackground)
        .consoleInput { command in
            switch command {
            case "up", "left": externalAction = max(externalAction - 1, 0)
            case "down", "right": externalAction = min(externalAction + 1, 4)
            case "confirm": performExternalAction(externalAction)
            case "back", "menu", "context": mode = nil
            default: break
            }
        }
        .onAppear {
            externalAction = 1
            openExternalBrowser()
        }
    }

    private func signInHeader(backLabel: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(studioAccent)
                Text("Store account sign-in").font(.system(size: 12)).foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            Button(backLabel) { if mode == nil { dismiss() } else { mode = nil } }
                .buttonStyle(ConsoleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 15)
    }

    private func modeButton(_ label: String, detail: String, index: Int) -> some View {
        Button { modeSelection = index; selectMode(index) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 11)).opacity(0.65)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(modeSelection == index ? studioBackground : .white.opacity(0.86))
            .padding(.horizontal, 16).frame(height: 58)
            .background(modeSelection == index ? studioAccent : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(ConsoleButtonStyle())
        .consoleFocus(modeSelection == index, cornerRadius: 10)
        .accessibilityAddTraits(modeSelection == index ? [.isSelected] : [])
    }

    private func externalButton(_ label: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action, label: {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                if index == externalAction { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(externalAction == index ? studioBackground : .white.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 38)
            .background(externalAction == index ? studioAccent : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        })
        .buttonStyle(ConsoleButtonStyle())
        .consoleFocus(externalAction == index, cornerRadius: 8)
    }

    private func selectMode(_ index: Int) {
        switch index {
        case 0:
            mode = .internalBrowser
            session.externalAuthenticationMessage = ""
            session.loadAddress(url.absoluteString)
        case 1:
            mode = .externalBrowser
        default: dismiss()
        }
    }

    private func openExternalBrowser() {
        session.openExternalAuthentication(url)
    }

    private func pasteCode() {
        guard let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty else {
            session.externalAuthenticationMessage = "The clipboard is empty. Copy the code or redirect URL from your browser first."
            return
        }
        code = clipboard
    }

    private func performExternalAction(_ index: Int) {
        switch index {
        case 0: openExternalBrowser()
        case 1: pasteCode()
        case 2: keyboardOpen = true
        case 3: finish(code)
        default: mode = nil
        }
    }

    private func finish(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        complete(value)
        dismiss()
    }

    private func syncBackgroundControllerAction() {
        guard mode == .externalBrowser || !session.externalAuthenticationMessage.isEmpty else {
            controller.inactiveAppAction = nil
            return
        }
        controller.inactiveAppAction = { command in
            guard command == "home" || command == "back" else { return false }
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
    }
}
