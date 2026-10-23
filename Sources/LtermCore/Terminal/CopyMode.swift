import Foundation

/// A row and column in the terminal text (rows count from the top of scrollback).
public struct TextPosition: Equatable, Comparable, Sendable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

/// Read access to the terminal text, so copy mode can be tested without a terminal.
public protocol CopyModeText {
    var lineCount: Int { get }
    func line(_ row: Int) -> String
    /// True when `row` is a soft wrap of the row above it (no newline between them).
    func isWrapped(_ row: Int) -> Bool
}

/// Simple in-memory text, used by tests.
public struct StaticText: CopyModeText {
    public var lines: [String]
    public var wrapped: Set<Int>

    public init(_ lines: [String], wrapped: Set<Int> = []) {
        self.lines = lines
        self.wrapped = wrapped
    }

    public var lineCount: Int { lines.count }
    public func line(_ row: Int) -> String { lines.indices.contains(row) ? lines[row] : "" }
    public func isWrapped(_ row: Int) -> Bool { wrapped.contains(row) }
}

/// Vim-style keyboard selection over the scrollback.
public struct CopyMode: Sendable {
    public enum Selection: Sendable { case none, characters, lines }

    public enum Result: Equatable, Sendable {
        /// The cursor or selection changed; redraw.
        case moved
        /// Text to put on the clipboard. Copy mode ends.
        case copied(String)
        /// Leave copy mode without copying.
        case exit
        /// Ask the user for a search term (then call `search`).
        case startSearch
        /// Nothing happened (unknown key or no match).
        case beep
    }

    public private(set) var cursor: TextPosition
    public private(set) var anchor: TextPosition?
    public private(set) var selection: Selection = .none
    public private(set) var lastSearch: String?
    /// Rows moved by ctrl-u / ctrl-d is half of this.
    public var pageHeight: Int
    private var desiredCol: Int

    public init(cursor: TextPosition, pageHeight: Int = 24) {
        self.cursor = cursor
        self.pageHeight = max(pageHeight, 2)
        desiredCol = cursor.col
    }

    /// Handles one key. Keys are plain characters ("h", "G", "$") or names ("esc", "enter", "ctrl-u", "ctrl-d").
    public mutating func handle(_ key: String, in text: CopyModeText) -> Result {
        let last = max(text.lineCount - 1, 0)
        switch key {
        case "h":
            cursor.col = max(min(cursor.col, maxCol(cursor.row, text)) - 1, 0)
            desiredCol = cursor.col
        case "l":
            cursor.col = min(cursor.col + 1, maxCol(cursor.row, text))
            desiredCol = cursor.col
        case "j": moveRow(to: cursor.row + 1, text)
        case "k": moveRow(to: cursor.row - 1, text)
        case "ctrl-d": moveRow(to: cursor.row + pageHeight / 2, text)
        case "ctrl-u": moveRow(to: cursor.row - pageHeight / 2, text)
        case "g":
            cursor = TextPosition(row: 0, col: 0)
            desiredCol = 0
        case "G":
            moveRow(to: last, text)
        case "0":
            cursor.col = 0
            desiredCol = 0
        case "$":
            cursor.col = maxCol(cursor.row, text)
            desiredCol = Int.max
        case "w": wordForward(text)
        case "b": wordBackward(text)
        case "v": toggle(.characters)
        case "V": toggle(.lines)
        case "y", "enter":
            guard let copied = selectedText(in: text) else { return .exit }
            return .copied(copied)
        case "/":
            return .startSearch
        case "n", "N":
            guard let term = lastSearch else { return .beep }
            return search(term, forward: key == "n", in: text) ? .moved : .beep
        case "q", "esc":
            if selection != .none && key == "esc" {
                selection = .none
                anchor = nil
                return .moved
            }
            return .exit
        default:
            return .beep
        }
        return .moved
    }

    /// Moves the cursor to the next (or previous) match. Smart case: lowercase terms ignore case.
    @discardableResult
    public mutating func search(_ term: String, forward: Bool = true, in text: CopyModeText) -> Bool {
        guard !term.isEmpty, text.lineCount > 0 else { return false }
        lastSearch = term
        let ignoreCase = term == term.lowercased()
        let needle = ignoreCase ? term.lowercased() : term
        let count = text.lineCount
        func matches(in row: Int) -> [Int] {
            let line = ignoreCase ? text.line(row).lowercased() : text.line(row)
            var cols: [Int] = []
            var searchStart = line.startIndex
            while searchStart < line.endIndex, let range = line.range(of: needle, range: searchStart..<line.endIndex) {
                cols.append(line.distance(from: line.startIndex, to: range.lowerBound))
                searchStart = line.index(after: range.lowerBound)
            }
            return cols
        }
        for step in 0...count {
            let row = forward ? (cursor.row + step) % count : (cursor.row - step + count * 2) % count
            let cols = matches(in: row)
            let hit: Int?
            if step == 0 {
                hit = forward ? cols.first { $0 > cursor.col } : cols.last { $0 < cursor.col }
            } else if step == count {
                // Wrapped all the way back to the start row.
                hit = forward ? cols.first { $0 <= cursor.col } : cols.last { $0 >= cursor.col }
            } else {
                hit = forward ? cols.first : cols.last
            }
            if let hit {
                cursor = TextPosition(row: row, col: hit)
                desiredCol = hit
                return true
            }
        }
        return false
    }

    /// The selected range, start before end, both inclusive. Line mode covers whole lines.
    public func selectedRange(in text: CopyModeText) -> (start: TextPosition, end: TextPosition)? {
        guard let anchor, selection != .none else { return nil }
        let (a, b) = anchor < cursor ? (anchor, cursor) : (cursor, anchor)
        if selection == .lines {
            return (TextPosition(row: a.row, col: 0), TextPosition(row: b.row, col: maxCol(b.row, text)))
        }
        return (a, b)
    }

    /// The selected text. Soft-wrapped rows are joined without a newline.
    public func selectedText(in text: CopyModeText) -> String? {
        guard let (start, end) = selectedRange(in: text) else { return nil }
        var result = ""
        for row in start.row...end.row {
            let chars = Array(text.line(row))
            let from = row == start.row ? min(start.col, chars.count) : 0
            let to = row == end.row ? min(end.col + 1, chars.count) : chars.count
            if from < to { result += String(chars[from..<to]) }
            if row != end.row && !text.isWrapped(row + 1) { result += "\n" }
        }
        if selection == .lines { result += "\n" }
        return result
    }

    // MARK: Helpers

    private mutating func toggle(_ mode: Selection) {
        if selection == mode {
            selection = .none
            anchor = nil
        } else {
            if selection == .none { anchor = cursor }
            selection = mode
        }
    }

    private func maxCol(_ row: Int, _ text: CopyModeText) -> Int {
        max(text.line(row).count - 1, 0)
    }

    private mutating func moveRow(to row: Int, _ text: CopyModeText) {
        cursor.row = min(max(row, 0), max(text.lineCount - 1, 0))
        cursor.col = min(desiredCol, maxCol(cursor.row, text))
    }

    private enum CharClass { case space, word, punct }

    private static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .space }
        if c.isLetter || c.isNumber || c == "_" { return .word }
        return .punct
    }

    /// Vim `w`: start of the next word, crossing lines.
    private mutating func wordForward(_ text: CopyModeText) {
        var row = cursor.row
        var chars = Array(text.line(row))
        var col = cursor.col
        if col < chars.count {
            let start = Self.charClass(chars[col])
            while col < chars.count, Self.charClass(chars[col]) == start, start != .space { col += 1 }
        }
        while true {
            while col < chars.count, Self.charClass(chars[col]) == .space { col += 1 }
            if col < chars.count { break }
            guard row + 1 < text.lineCount else {
                col = max(chars.count - 1, 0)
                break
            }
            row += 1
            chars = Array(text.line(row))
            col = 0
            if chars.isEmpty { break }
        }
        cursor = TextPosition(row: row, col: col)
        desiredCol = col
    }

    /// Vim `b`: start of the previous word, crossing lines.
    private mutating func wordBackward(_ text: CopyModeText) {
        var row = cursor.row
        var chars = Array(text.line(row))
        var col = min(cursor.col, chars.count) - 1
        while true {
            while col >= 0, Self.charClass(chars[col]) == .space { col -= 1 }
            if col >= 0 { break }
            guard row > 0 else {
                col = 0
                cursor = TextPosition(row: row, col: 0)
                desiredCol = 0
                return
            }
            row -= 1
            chars = Array(text.line(row))
            col = chars.count - 1
        }
        let cls = Self.charClass(chars[col])
        while col > 0, Self.charClass(chars[col - 1]) == cls { col -= 1 }
        cursor = TextPosition(row: row, col: col)
        desiredCol = col
    }
}
