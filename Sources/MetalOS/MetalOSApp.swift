import AppKit
import SwiftUI

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ConsoleShellCoordinator.shared.launchShell()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        ConsoleShellCoordinator.shared.showShell()
        return true
    }

    func toggleConsoleFullscreen() { ConsoleShellCoordinator.shared.toggleFullscreen() }

    func moveConsole(toDisplay displayName: String) {
        ConsoleSettingsStore.shared.targetDisplay = displayName
        ConsoleShellCoordinator.shared.setTargetDisplay(displayName)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}


@main
struct MetalOSApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ConsoleLauncherView()
                .background(ConsoleWindowAccessor { window in
                    ConsoleShellCoordinator.shared.adoptSceneWindow(window)
                }.frame(width: 0, height: 0))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

private struct ConsoleWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow?(window)
        }
    }
}
