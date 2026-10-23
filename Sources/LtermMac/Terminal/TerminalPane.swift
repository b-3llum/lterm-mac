import AppKit
import Darwin
import SwiftTerm

/// A pane running a process (by default the login shell) inside SwiftTerm.
@MainActor
final class TerminalPane: NSObject, Pane {
    let id: Int
    let terminalView: LtermTerminalView
    weak var owner: PaneOwner?
    private(set) var title: String
    private var exited = false

    var view: NSView { terminalView }
    var focusView: NSView { terminalView }
    var kind: String { "terminal" }

    init(id: Int) {
        self.id = id
        terminalView = LtermTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        title = (Shell.loginShell as NSString).lastPathComponent
        super.init()
        terminalView.processDelegate = self
        terminalView.font = Settings.font
        terminalView.optionAsMetaKey = true
    }

    /// Starts the login shell, or runs `command` through it when given.
    func start(command: String? = nil, directory: String? = nil, extraEnvironment: [String: String] = [:]) {
        let shell = Shell.loginShell
        let shellName = (shell as NSString).lastPathComponent
        var extra = extraEnvironment
        extra["LTERM_PANE_ID"] = String(id)
        let env = Shell.environment(extra: extra)
        var args: [String] = []
        if let command {
            args = ["-l", "-c", command]
            title = command
        }
        terminalView.startProcess(
            executable: shell,
            args: args,
            environment: env,
            execName: command == nil ? "-" + shellName : shellName,
            currentDirectory: directory ?? NSHomeDirectory()
        )
    }

    /// The shell's current directory, read from the process table.
    var currentDirectory: String? {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func setFont(_ font: NSFont) {
        terminalView.font = font
    }

    func close() {
        exited = true
        if terminalView.process.running { terminalView.terminate() }
    }

    func readText(lines: Int) -> String {
        let terminal = terminalView.getTerminal()
        // Walk every kept line from the top of scrollback, then trim trailing blank lines.
        var rows: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            rows.append(line.translateToString(trimRight: true))
            row += 1
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.suffix(max(lines, 1)).joined(separator: "\n")
    }

    /// Types text into the program as if it was pasted from the keyboard.
    func send(text: String) {
        terminalView.send(txt: text)
    }

    func send(bytes: [UInt8]) {
        terminalView.send(data: bytes[...])
    }
}

extension TerminalPane: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        owner?.paneTitleChanged(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        owner?.paneExited(self)
    }
}

/// SwiftTerm's local process view, subclassed so lterm can hook output and keys.
final class LtermTerminalView: LocalProcessTerminalView {}
