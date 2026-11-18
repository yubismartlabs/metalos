import SwiftUI
import AppKit

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var builder: NXBuildService?
    var library: LibraryStore?
    private var fallbackWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in self?.ensureLibraryWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { ensureLibraryWindow() }
        return true
    }
    private func ensureLibraryWindow() {
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        guard let library else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MetalOS"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LibraryView().environmentObject(library).frame(minWidth: 1000, minHeight: 680).preferredColorScheme(.dark))
        fallbackWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
        GameOverlayController.shared.configure(store: library)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { builder?.cancel() }
}

@main
struct MetalOSApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var library: LibraryStore
    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        delegate.library = store
        delegate.builder = store.builder
    }
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.builder = library.builder
                    GameOverlayController.shared.configure(store: library)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Mac Game…") { library.importApp() }.keyboardShortcut("o")
                Button("Import Switch Game…") { library.showImport = true }.keyboardShortcut("i")
                Button("Scan Libraries") { Task { await library.scan() } }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { library.showSettings = true }.keyboardShortcut(",") }
            CommandMenu("Library") {
                Button("Game Bar") { GameOverlayController.shared.showFromLibrary() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Toggle Console Mode") { library.toggleConsole() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
