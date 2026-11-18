import AppKit
import SwiftUI

/// Window-scoped keyboard routing also works after a mouse click changes SwiftUI focus.
struct LibraryKeyHandler: NSViewRepresentable {
    var enabled: Bool
    var onCommand: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onCommand = onCommand
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }
    @MainActor final class Coordinator {
        var enabled = false
        var onCommand: ((String) -> Void)?
        private weak var view: NSView?
        private var monitor: Any?
        func attach(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, NSApp.modalWindow == nil,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let owner = self.view?.window, let target = event.window ?? NSApp.keyWindow,
                      target === owner || target.sheetParent === owner else { return event }
                if let editor = target.firstResponder as? NSTextView, editor.isEditable { return event }
                if let field = target.firstResponder as? NSTextField, field.isEditable { return event }
                let keys: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "confirm", 76: "confirm", 53: "back", 49: "context"]
                let command = keys[event.keyCode] ?? (event.charactersIgnoringModifiers?.lowercased() == "m" ? "context" : nil)
                guard let command else { return event }
                ConsoleFeedback.shared.respond(to: command)
                self.onCommand?(command)
                return nil
            }
        }
        func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
