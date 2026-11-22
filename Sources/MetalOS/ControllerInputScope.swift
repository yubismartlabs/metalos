import Combine
import SwiftUI

private struct ConsoleInputModifier: ViewModifier {
    @ObservedObject private var controller = ControllerManager.shared
    @State private var token: UUID?
    @State private var commands = PassthroughSubject<String, Never>()
    let keyboardShortcuts: [String: String]
    let onCommand: (String) -> Void
    func body(content: Content) -> some View {
        content
            .consoleMotion()
            .environment(\.consoleFocusScopeID, token)
            .background {
                LibraryKeyHandler(enabled: token != nil && controller.activeInputScopeID == token,
                                  shortcuts: keyboardShortcuts) { command in
                    onCommand(command)
                }
            }
            .onAppear {
                // Keep the registration stable while SwiftUI updates the handler below.
                if token == nil { token = controller.pushInputHandler(commands.send) }
            }
            .onReceive(commands, perform: onCommand)
            .onDisappear {
                if let token { controller.popInputHandler(token) }; token = nil
            }
    }
}
extension View {
    func consoleInput(keyboardShortcuts: [String: String] = [:],
                      onCommand: @escaping (String) -> Void) -> some View {
        modifier(ConsoleInputModifier(keyboardShortcuts: keyboardShortcuts, onCommand: onCommand))
    }
}
