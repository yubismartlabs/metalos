import SwiftUI
import AppKit

struct FirstRunSetupView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedFolder: URL?
    @State private var showingPicker = false
    @State private var selection = 0

    private var choices: Int { selectedFolder == nil ? 1 : 2 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.11, blue: 0.23), studioBackground], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("METALOS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.5).foregroundStyle(.white.opacity(0.62))
                    Spacer()
                    Text("ONE-TIME SETUP").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(studioAccent)
                }.padding(.horizontal, 54).padding(.top, 34)
                Spacer(minLength: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("01  ·  YOUR LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(studioAccent)
                    Text("Choose a home\nfor your games.")
                        .font(.system(size: 48, weight: .light)).tracking(-1.8).lineSpacing(-3).padding(.top, 17)
                    Text("Choose one folder for your Switch game library and MetalOS data. Game folders, NXNative, artwork, and app settings will stay together here.")
                        .font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.62)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 630, alignment: .leading).padding(.top, 14)

                    HStack(spacing: 15) {
                        Image(systemName: "externaldrive.fill").font(.system(size: 20, weight: .light)).foregroundStyle(studioAccent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selectedFolder == nil ? "LIBRARY FOLDER" : "SELECTED FOLDER")
                                .font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.44))
                            Text(selectedFolder?.path ?? "Choose a folder on this Mac or an external drive")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(selectedFolder == nil ? .white.opacity(0.52) : .white.opacity(0.9))
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if selectedFolder != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(studioAccent) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.09)))
                        .padding(.top, 28)

                    HStack(spacing: 12) {
                        setupButton("Choose folder", symbol: "folder", index: 0, primary: selectedFolder == nil) {
                            showingPicker = true
                        }
                        if selectedFolder != nil {
                            setupButton("Continue", symbol: "arrow.right", index: 1, primary: true) {
                                guard let selectedFolder else { return }
                                store.completeInitialSetup(at: selectedFolder)
                            }
                        }
                    }.padding(.top, 17)
                    if let notice = store.notice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 12)
                    }
                    Text("MetalOS will create its data and engine folders here. Your game folders remain separate entries inside this library.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.38)).lineSpacing(4).padding(.top, 20)
                }.frame(maxWidth: 670, alignment: .leading)
                Spacer(minLength: 28)
                HStack(spacing: 20) {
                    Text("↑ ↓  Navigate")
                    Text("A / ✕  Select")
                    Text("Choose a folder to continue")
                    Spacer()
                    Image(systemName: "gamecontroller.fill").foregroundStyle(.white.opacity(0.32))
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 54).frame(height: 49)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            }
        }
        .preferredColorScheme(.dark)
        .tint(studioAccent)
        .consoleInput(onCommand: navigate)
        .onAppear {
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }),
                      window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
        .consoleSheet(isPresented: $showingPicker) {
            ConsoleFilePicker(title: "Choose your game library folder", mode: .directory, startingPath: selectedFolder?.path ?? defaultFolder()) { url in
                selectedFolder = url.standardizedFileURL
                selection = 1
                showingPicker = false
            }
        }
    }

    private func setupButton(_ title: String, symbol: String, index: Int, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            selection = index
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? studioBackground : .white.opacity(0.86))
                .padding(.horizontal, 19).frame(height: 43)
                .background(primary ? studioAccent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ConsoleButtonStyle())
            .consoleFocus(selection == index, cornerRadius: 9, scale: 1.035)
            .accessibilityAddTraits(selection == index ? [.isSelected] : [])
    }

    private func navigate(_ command: String) {
        switch command {
        case "up", "left": selection = max(selection - 1, 0)
        case "down", "right": selection = min(selection + 1, choices - 1)
        case "confirm":
            if selectedFolder == nil || selection == 0 { showingPicker = true }
            else if let selectedFolder { store.completeInitialSetup(at: selectedFolder) }
        case "back", "menu", "context": break
        default: break
        }
    }

    private func defaultFolder() -> String? {
        let games = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games", isDirectory: true)
        return FileManager.default.fileExists(atPath: games.path) ? games.path : nil
    }
}
