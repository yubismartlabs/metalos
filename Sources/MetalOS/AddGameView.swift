import SwiftUI

struct AddGameView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let onSwitch: () -> Void
    @State private var selection = 0
    @State private var picker: ConsoleFilePicker.Mode?
    @State private var pending: (URL, ConsoleFilePicker.Mode)?
    @State private var appToAdd: URL?
    @State private var appTitle = ""
    @State private var showAddConfirmation = false
    private let options = [("Add a Mac app", "Choose a game or another .app.", "app"), ("Add a Switch game", "Choose its folder. Updates and DLC stay together; Play builds it for Mac.", "gamecontroller"), ("Back to games", "", "arrow.uturn.backward")]
    var body: some View {
        Group {
            if appToAdd != nil {
                SearchKeyboardView(query: $appTitle, title: "Name this game", subtitle: "Type with your Mac keyboard or use the on-screen gamepad keyboard.", doneTitle: "Add game", focusTextFieldOnAppear: true, onCancel: { self.appToAdd = nil }, onDone: addSelectedApp)
            } else {
                addMenu
            }
        }
        .consoleSheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }), onDismiss: finishSelection) {
            if let mode = picker {
                ConsoleFilePicker(title: mode == .application ? "Choose a game application" : "Choose a library folder", mode: mode, startingPath: mode == .application ? "/Applications" : nil) { url in
                    pending = (url, mode); picker = nil
                }
            }
        }
        .consoleSheet(isPresented: $showAddConfirmation) {
            ActionConfirmationView(title: "Add \(appTitle.isEmpty ? "this app" : appTitle)?", message: "MetalOS will add this app to your library using the title you entered. The app stays in its current location.", confirmTitle: "Add app", onConfirm: confirmSelectedApp)
        }
    }
    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Add to your collection").font(.system(size: 32, weight: .light))
            Text("Point MetalOS to a game or folder. The rest happens automatically.").foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { index in
                    Button { selection = index; activate() } label: {
                        HStack(spacing: 20) {
                            Image(systemName: options[index].2).font(.system(size: 24, weight: .light)).frame(width: 36)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(options[index].0).font(.system(size: 17, weight: .medium))
                                if !options[index].1.isEmpty { Text(options[index].1).font(.system(size: 12)).opacity(0.6) }
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(selection == index ? studioBackground : .white.opacity(0.85))
                            .background(selection == index ? studioAccent : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selection == index, cornerRadius: 13, scale: 1.025).accessibilityAddTraits(selection == index ? [.isSelected] : [])
                }
            }
            Text("↑ ↓  Choose     A / ×  Select     B / ○  Back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(30).frame(width: 740).background(studioBackground).preferredColorScheme(.dark)
            .animation(ConsoleFeedback.shared.focusAnimation, value: selection)
            .consoleInput { command in
                switch command {
                case "up", "left": selection = max(selection - 1, 0)
                case "down", "right": selection = min(selection + 1, options.count - 1)
                case "confirm": activate()
                case "back", "menu", "context": dismiss()
                default: break
                }
            }
    }
    private func activate() {
        switch selection {
        case 0: picker = .application
        case 1: onSwitch()
        default: dismiss()
        }
    }
    private func finishSelection() {
        guard let (url, mode) = pending else { return }; pending = nil
        if mode == .application {
            appToAdd = url
            appTitle = store.suggestedMacAppTitle(at: url)
        }
    }
    private func addSelectedApp() {
        guard appToAdd != nil else { return }
        showAddConfirmation = true
    }
    private func confirmSelectedApp() {
        guard let appToAdd, store.addMacApp(at: appToAdd, title: appTitle) else { return }
        dismiss()
    }
}
