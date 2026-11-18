import SwiftUI

private struct ConsoleInputModifier: ViewModifier {
    @ObservedObject private var controller = ControllerManager.shared
    @State private var token: UUID?
    let onCommand: (String) -> Void
    func body(content: Content) -> some View {
        content
            .consoleMotion()
            .environment(\.consoleFocusScopeID, token)
            .background {
                LibraryKeyHandler(enabled: token != nil && controller.activeInputScopeID == token) { command in
                    onCommand(command)
                }
            }
            .onAppear {
                if token == nil { token = controller.pushInputHandler(onCommand) }
            }
            .onDisappear {
                if let token { controller.popInputHandler(token) }; token = nil
            }
    }
}
extension View {
    func consoleInput(onCommand: @escaping (String) -> Void) -> some View {
        modifier(ConsoleInputModifier(onCommand: onCommand))
    }
}
