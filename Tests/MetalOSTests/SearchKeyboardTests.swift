import XCTest
@testable import MetalOS

final class SearchKeyboardTests: XCTestCase {
    func testNavigationAcrossUnevenRowsAlwaysSelectsAKey() {
        var state = SearchKeyboardState()
        for command in ["right", "right", "up", "left", "down", "down", "down", "down", "right", "right", "up", "up", "up", "up"] {
            state.move(command)
            XCTAssertTrue(state.rows.indices.contains(state.row))
            XCTAssertTrue(state.rows[state.row].indices.contains(state.column))
        }
        XCTAssertEqual(state.selected, state.rows[state.row][state.column])
    }
    func testDeleteHandlesUnicodeAndSearchDoesNotAlterText() {
        var state = SearchKeyboardState(), text = "Game 🎮"
        state.press(.backspace, text: &text)
        XCTAssertEqual(text, "Game ")
        state.press(.clear, text: &text)
        state.press(.backspace, text: &text)
        XCTAssertEqual(text, "")
        XCTAssertTrue(state.press(.done, text: &text))
        XCTAssertEqual(text, "")
    }
    func testShiftSymbolsAndInputLimit() {
        var state = SearchKeyboardState(), text = ""
        state.press(.shift, text: &text)
        XCTAssertEqual(state.rows[1][0], .character("Q"))
        state.press(.symbols, text: &text)
        XCTAssertEqual(state.rows[1][0], .character("!"))
        state.press(.character("!"), text: &text)
        state.press(.space, text: &text)
        XCTAssertEqual(text, "! ")
        text = String(repeating: "a", count: 128)
        state.press(.character("b"), text: &text)
        XCTAssertEqual(text.count, 128)
    }
}
