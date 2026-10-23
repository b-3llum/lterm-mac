import AppKit
import SwiftTerm
import LtermCore

/// Terminal text as seen by copy mode. Rows are indexes into SwiftTerm's line buffer.
/// Only used on the main thread, like the terminal itself.
struct TerminalText: CopyModeText {
    let terminal: Terminal
    let lineCount: Int

    init(terminal: Terminal) {
        self.terminal = terminal
        // The buffer line count is not public, so probe for the last line.
        let first = terminal.buffer.totalLinesTrimmed
        var count = terminal.buffer.yDisp + terminal.rows
        while terminal.getScrollInvariantLine(row: first + count) != nil { count += 1 }
        while count > 0, terminal.getScrollInvariantLine(row: first + count - 1) == nil { count -= 1 }
        lineCount = count
    }

    private func bufferLine(_ row: Int) -> BufferLine? {
        terminal.getScrollInvariantLine(row: row + terminal.buffer.totalLinesTrimmed)
    }

    func line(_ row: Int) -> String {
        bufferLine(row)?.translateToString(trimRight: true) ?? ""
    }

    func isWrapped(_ row: Int) -> Bool {
        bufferLine(row)?.isWrapped ?? false
    }
}

/// Runs copy mode on one terminal pane: moves a cursor and selection with vim keys.
@MainActor
final class CopyModeController {
    private let view: LtermTerminalView
    private var mode: CopyMode
    /// Text being typed after "/", nil when not searching.
    private var searchInput: String?
    var onEnd: (() -> Void)?

    init(view: LtermTerminalView) {
        self.view = view
        let terminal = view.getTerminal()
        let buffer = terminal.buffer
        let start = TextPosition(row: buffer.yDisp + min(buffer.y, terminal.rows - 1), col: buffer.x)
        mode = CopyMode(cursor: start, pageHeight: terminal.rows)
        render()
    }

    /// What the tab bar shows while copy mode is on.
    var indicator: String {
        if let searchInput { return "COPY  /\(searchInput)" }
        switch mode.selection {
        case .none: return "COPY"
        case .characters: return "COPY  VISUAL"
        case .lines: return "COPY  VISUAL LINE"
        }
    }

    /// Handles a key. Copy mode eats every key while it is on.
    func handle(_ event: NSEvent) {
        let text = TerminalText(terminal: view.getTerminal())
        if var input = searchInput {
            switch event.keyCode {
            case 53: // escape
                searchInput = nil
            case 36, 76: // return
                searchInput = nil
                if !mode.search(input, forward: true, in: text) { NSSound.beep() }
            case 51: // delete
                if !input.isEmpty { input.removeLast() }
                searchInput = input
            default:
                if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                    input += chars
                }
                searchInput = input
            }
            render()
            return
        }
        guard let key = Self.keyName(event) else { return }
        switch mode.handle(key, in: text) {
        case .moved:
            render()
        case .copied(let string):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
            finish()
        case .exit:
            finish()
        case .startSearch:
            searchInput = ""
            render()
        case .beep:
            NSSound.beep()
        }
    }

    /// Leaves copy mode, clears the highlight and scrolls back to the bottom.
    func finish() {
        view.selection.selectNone()
        view.scrollTo(row: Int.max)
        onEnd?()
    }

    /// Shows the selection, or a one-cell block at the cursor, and keeps the cursor on screen.
    private func render() {
        let terminal = view.getTerminal()
        let text = TerminalText(terminal: terminal)
        let cursor = mode.cursor
        if let (start, end) = mode.selectedRange(in: text) {
            view.selection.setSelection(start: Position(col: start.col, row: start.row),
                                        end: Position(col: end.col + 1, row: end.row))
        } else {
            view.selection.setSelection(start: Position(col: cursor.col, row: cursor.row),
                                        end: Position(col: cursor.col + 1, row: cursor.row))
        }
        let top = terminal.buffer.yDisp
        if cursor.row < top {
            view.scrollTo(row: cursor.row)
        } else if cursor.row >= top + terminal.rows {
            view.scrollTo(row: cursor.row - terminal.rows + 1)
        }
        view.needsDisplay = true
        onChange?()
    }

    var onChange: (() -> Void)?

    static func keyName(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "esc"
        case 36, 76: return "enter"
        case 123: return "h"
        case 124: return "l"
        case 125: return "j"
        case 126: return "k"
        default: break
        }
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "u" || chars == "d" { return "ctrl-" + chars }
            return nil
        }
        return event.characters
    }
}
