import XCTest
@testable import LtermCore

final class CopyModeTests: XCTestCase {
    let text = StaticText(["hello world", "  foo.bar baz", "", "last line"])

    private func run(_ keys: [String], from start: TextPosition = TextPosition(row: 0, col: 0)) -> CopyMode {
        var mode = CopyMode(cursor: start)
        for key in keys { _ = mode.handle(key, in: text) }
        return mode
    }

    func testBasicMotions() {
        XCTAssertEqual(run(["l", "l", "h"]).cursor, TextPosition(row: 0, col: 1))
        XCTAssertEqual(run(["$"]).cursor, TextPosition(row: 0, col: 10))
        XCTAssertEqual(run(["$", "0"]).cursor, TextPosition(row: 0, col: 0))
        XCTAssertEqual(run(["G"]).cursor.row, 3)
        XCTAssertEqual(run(["G", "g"]).cursor, TextPosition(row: 0, col: 0))
        XCTAssertEqual(run(["k", "h"]).cursor, TextPosition(row: 0, col: 0), "clamped at the top left")
    }

    func testVerticalMoveRemembersColumn() {
        let mode = run(["$", "j", "j", "j"])
        XCTAssertEqual(mode.cursor, TextPosition(row: 3, col: 8), "$ sticks to the end of each line")
    }

    func testWordMotions() {
        XCTAssertEqual(run(["w"]).cursor, TextPosition(row: 0, col: 6))
        XCTAssertEqual(run(["w", "w"]).cursor, TextPosition(row: 1, col: 2), "crosses to the next line")
        XCTAssertEqual(run(["w", "w", "w"]).cursor, TextPosition(row: 1, col: 5), "punctuation is its own word")
        XCTAssertEqual(run(["b"], from: TextPosition(row: 1, col: 2)).cursor, TextPosition(row: 0, col: 6))
    }

    func testCharacterSelectionCopiesAcrossLines() {
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 6))
        XCTAssertEqual(mode.handle("v", in: text), .moved)
        _ = mode.handle("j", in: text)
        XCTAssertEqual(mode.handle("y", in: text), .copied("world\n  foo.b"))
    }

    func testLineSelection() {
        var mode = CopyMode(cursor: TextPosition(row: 1, col: 3))
        _ = mode.handle("V", in: text)
        _ = mode.handle("k", in: text)
        XCTAssertEqual(mode.handle("y", in: text), .copied("hello world\n  foo.bar baz\n"))
    }

    func testWrappedLinesJoinWithoutNewline() {
        let wrapped = StaticText(["abc", "def"], wrapped: [1])
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 0))
        _ = mode.handle("V", in: wrapped)
        _ = mode.handle("j", in: wrapped)
        XCTAssertEqual(mode.handle("y", in: wrapped), .copied("abcdef\n"))
    }

    func testYankWithoutSelectionExits() {
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 0))
        XCTAssertEqual(mode.handle("y", in: text), .exit)
        XCTAssertEqual(mode.handle("q", in: text), .exit)
        XCTAssertEqual(mode.handle("Z", in: text), .beep)
    }

    func testEscapeClearsSelectionFirst() {
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 0))
        _ = mode.handle("v", in: text)
        XCTAssertEqual(mode.handle("esc", in: text), .moved)
        XCTAssertEqual(mode.selection, .none)
        XCTAssertEqual(mode.handle("esc", in: text), .exit)
    }

    func testSearchForwardBackwardAndWrap() {
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 0))
        XCTAssertEqual(mode.handle("/", in: text), .startSearch)
        XCTAssertTrue(mode.search("ba", in: text))
        XCTAssertEqual(mode.cursor, TextPosition(row: 1, col: 6))
        XCTAssertEqual(mode.handle("n", in: text), .moved)
        XCTAssertEqual(mode.cursor, TextPosition(row: 1, col: 10))
        XCTAssertEqual(mode.handle("n", in: text), .moved, "wraps around")
        XCTAssertEqual(mode.cursor, TextPosition(row: 1, col: 6))
        XCTAssertEqual(mode.handle("N", in: text), .moved)
        XCTAssertEqual(mode.cursor, TextPosition(row: 1, col: 10))
        XCTAssertFalse(mode.search("nothing here", in: text))
    }

    func testSmartCase() {
        var mode = CopyMode(cursor: TextPosition(row: 0, col: 0))
        XCTAssertTrue(mode.search("LINE", in: StaticText(["x", "a line", "a LINE"])))
        XCTAssertEqual(mode.cursor, TextPosition(row: 2, col: 2), "uppercase term matches case")
        var lower = CopyMode(cursor: TextPosition(row: 0, col: 0))
        XCTAssertTrue(lower.search("line", in: StaticText(["x", "a LINE"])))
        XCTAssertEqual(lower.cursor, TextPosition(row: 1, col: 2))
    }
}
