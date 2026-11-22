import SwiftUI

enum ConsoleDirection: String, Hashable {
    case up, down, left, right
}

enum ConsoleCommand: Equatable {
    case move(ConsoleDirection)
    case confirm, back, details, secondary, previousTab, nextTab, menu, context, guide

    init?(input: String) {
        if let direction = ConsoleDirection(rawValue: input) {
            self = .move(direction)
            return
        }
        switch input {
        case "confirm": self = .confirm
        case "back": self = .back
        case "details": self = .details
        case "favorite": self = .secondary
        case "previous": self = .previousTab
        case "next": self = .nextTab
        case "menu": self = .menu
        case "context": self = .context
        case "home": self = .guide
        default: return nil
        }
    }
}

/// A screen supplies one graph for its active surface. SwiftUI owns the selected ID.
struct GamepadNavigationManager<ID: Hashable> {
    let entry: ID?
    let enabled: Set<ID>
    let neighbors: [ID: [ConsoleDirection: ID]]

    /// Use after opening a surface or when its available controls change.
    func restoredFocus(_ preferred: ID?) -> ID? {
        if let preferred, enabled.contains(preferred) { return preferred }
        if let entry, enabled.contains(entry) { return entry }
        return nil
    }

    @MainActor
    func handle(
        _ command: ConsoleCommand,
        focus: FocusState<ID?>.Binding,
        activate: (ID) -> Void,
        perform: (ConsoleCommand) -> Void,
        didMoveFocus: (ID) -> Void = { _ in }
    ) {
        let current = focus.wrappedValue

        switch command {
        case .move(let direction):
            let next: ID?
            if let current, enabled.contains(current) {
                next = neighbors[current]?[direction]
            } else {
                next = restoredFocus(nil)
            }
            guard let next, next != current, enabled.contains(next) else { return }
            focus.wrappedValue = next
            didMoveFocus(next)
        case .confirm:
            guard let current, enabled.contains(current) else {
                // Recover focus without accidentally activating the entry action.
                focus.wrappedValue = restoredFocus(nil)
                return
            }
            activate(current)
        default:
            perform(command)
        }
    }
}

extension View {
    /// Joins MetalOS's modal input stack and window keyboard routing.
    func consoleNavigation(onCommand: @escaping (ConsoleCommand) -> Void) -> some View {
        consoleInput(keyboardShortcuts: ["q": "previous", "e": "next", "y": "favorite", "p": "home"]) { input in
            guard let command = ConsoleCommand(input: input) else { return }
            onCommand(command)
        }
    }
}
