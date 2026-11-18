import SwiftUI

// Shared by the visible keys and directional controller navigation.
enum SearchKeyboardKey: Hashable {
    case character(String), shift, symbols, clear, space, backspace, done
    var title: String {
        switch self {
        case .character(let value): value
        case .shift: "⇧"
        case .symbols: "#+="
        case .clear: "Clear"
        case .space: "Space"
        case .backspace: "⌫"
        case .done: "Search"
        }
    }
}
struct SearchKeyboardState {
    var row = 1
    var column = 0
    var uppercase = false
    var symbols = false
    var rows: [[SearchKeyboardKey]] {
        let letters = symbols ? ["1234567890", "!@#$%^&*()", "-_+=[]{}:/", ".,?!'\"\\"] : ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm"]
        var result = letters.map { text in text.map { SearchKeyboardKey.character(uppercase && !symbols ? String($0).uppercased() : String($0)) } }
        result[3] = [.shift] + result[3] + [.backspace]
        result.append([.symbols, .clear, .space, .done])
        return result
    }
    var selected: SearchKeyboardKey { rows[row][min(column, rows[row].count - 1)] }
    mutating func move(_ command: String) {
        let oldCount = rows[row].count
        switch command {
        case "left": column = max(column - 1, 0)
        case "right": column = min(column + 1, oldCount - 1)
        case "up", "down":
            let position = (Double(column) + 0.5) / Double(oldCount)
            row = min(max(row + (command == "up" ? -1 : 1), 0), rows.count - 1)
            column = min(Int(position * Double(rows[row].count)), rows[row].count - 1)
        default: break
        }
    }
    @discardableResult mutating func press(_ key: SearchKeyboardKey, text: inout String) -> Bool {
        switch key {
        case .character(let value): if text.count < 128 { text += value }
        case .space: if text.count < 128 { text += " " }
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .clear: text = ""
        case .shift: uppercase.toggle()
        case .symbols: symbols.toggle(); column = min(column, rows[row].count - 1)
        case .done: return true
        }
        return false
    }
}
struct SearchKeyboardView: View {
    @Binding var query: String
    @FocusState private var textFieldFocused: Bool
    let title: String
    let subtitle: String
    let doneTitle: String
    let secure: Bool
    let focusTextFieldOnAppear: Bool
    let onDone: () -> Void
    let onCancel: (() -> Void)?
    @State private var keyboard = SearchKeyboardState()

    init(query: Binding<String>, title: String = "Search", subtitle: String = "Find something to play.", doneTitle: String = "Search", secure: Bool = false, focusTextFieldOnAppear: Bool = false, onCancel: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        _query = query
        self.title = title
        self.subtitle = subtitle
        self.doneTitle = doneTitle
        self.secure = secure
        self.focusTextFieldOnAppear = focusTextFieldOnAppear
        self.onCancel = onCancel
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 32, weight: .light))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { onCancel?() ?? onDone() }) { Image(systemName: "xmark").padding(10).background(.white.opacity(0.06), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).help("Back to games")
            }
            HStack(spacing: 14) {
                Image(systemName: secure ? "key.fill" : "magnifyingglass").foregroundStyle(studioAccent)
                Group {
                    if secure {
                        SecureField("Enter a value", text: $query).textFieldStyle(.plain).font(.system(size: 21, weight: .light)).focused($textFieldFocused)
                            .onSubmit(onDone)
                    } else {
                        TextField(title == "Search" ? "Search your collection" : "Enter text", text: $query).textFieldStyle(.plain).font(.system(size: 21, weight: .light)).focused($textFieldFocused)
                            .onSubmit(onDone)
                    }
                }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(ConsoleButtonStyle()) }
            }.padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
            VStack(spacing: 9) {
                ForEach(keyboard.rows.indices, id: \.self) { row in
                    HStack(spacing: 9) {
                        ForEach(Array(keyboard.rows[row].enumerated()), id: \.offset) { column, key in
                            keyButton(key, row: row, column: column)
                        }
                    }
                }
            }
            HStack(spacing: 13) {
                controlHint("D-pad", "Move")
                controlHint("A", keyboard.selected == .done ? doneTitle : "Type")
                controlHint("X", "Delete")
                controlHint("Y", "Space")
                controlHint("LB", keyboard.uppercase ? "Shift on" : "Shift")
                controlHint("RB", keyboard.symbols ? "Letters" : "Symbols")
                Spacer(minLength: 0)
                controlHint("B", "Cancel")
            }
        }.padding(30).frame(width: 860).background(studioBackground).preferredColorScheme(.dark)
            .animation(ConsoleFeedback.shared.focusAnimation, value: keyboard.row * 20 + keyboard.column)
            .consoleInput(onCommand: navigate)
            .onAppear {
                guard focusTextFieldOnAppear else { return }
                DispatchQueue.main.async { textFieldFocused = true }
            }
    }
    private func keyButton(_ key: SearchKeyboardKey, row: Int, column: Int) -> some View {
        let selected = keyboard.row == row && keyboard.column == column
        let label: String = switch key {
        case .symbols: keyboard.symbols ? "ABC" : "#+="
        case .shift: keyboard.uppercase ? "⇧ ON" : "⇧"
        case .done: doneTitle
        default: key.title
        }
        let active = (key == .shift && keyboard.uppercase) || (key == .symbols && keyboard.symbols)
        return Button {
            keyboard.row = row; keyboard.column = column; press(key)
        } label: {
            Text(label).font(.system(size: key == .done || row == 4 ? 13 : 18, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(selected ? studioBackground : .white.opacity(0.85))
                .background(selected ? studioAccent : active ? studioAccent.opacity(0.28) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

        }.buttonStyle(ConsoleButtonStyle()).consoleFocus(selected, cornerRadius: 8, scale: 1.09).accessibilityLabel(key == .backspace ? "Delete character" : label)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func controlHint(_ button: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(button).fontWeight(.bold).foregroundStyle(.white.opacity(0.72))
            Text(action).foregroundStyle(.secondary)
        }.font(.system(size: 9))
    }
    private func press(_ key: SearchKeyboardKey) {
        var value = query
        let done = keyboard.press(key, text: &value)
        query = value
        if done { onDone() }
    }
    private func navigate(_ command: String) {
        switch command {
        case "left", "right", "up", "down": keyboard.move(command)
        case "confirm": press(keyboard.selected)
        case "details": press(.backspace)
        case "favorite": press(.space)
        case "previous": press(.shift)
        case "next": press(.symbols)
        case "menu", "context", "back": onCancel?() ?? onDone()
        default: break
        }
    }
}
