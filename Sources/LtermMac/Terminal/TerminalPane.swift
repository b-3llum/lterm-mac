import AppKit
import Darwin
import SwiftTerm
import LtermCore

/// A pane running a process (by default the login shell) inside SwiftTerm.
@MainActor
final class TerminalPane: NSObject, Pane {
    let id: Int
    let terminalView: LtermTerminalView
    weak var owner: PaneOwner?
    private(set) var title: String
    private var exited = false
    /// Set while copy mode is on.
    private(set) var copyMode: CopyModeController?

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
        registerNotificationHandlers()
    }

    /// OSC 9, 777 and 99 desktop notifications mark the pane as needing the user.
    private func registerNotificationHandlers() {
        let paneID = id
        for code in [9, 777, 99] {
            terminalView.getTerminal().registerOscHandler(code: code) { data in
                guard let payload = String(bytes: data, encoding: .utf8),
                      let text = AgentRules.notificationText(code: code, payload: payload) else { return }
                // SwiftTerm parses output on the main queue (LocalProcess's default).
                MainActor.assumeIsolated {
                    AgentStore.shared.notify(pane: paneID, text: text)
                }
            }
        }
    }

    /// Starts the login shell, or runs `command` through it when given.
    func start(command: String? = nil, directory: String? = nil, extraEnvironment: [String: String] = [:]) {
        let shell = Shell.loginShell
        let shellName = (shell as NSString).lastPathComponent
        var extra = extraEnvironment
        extra[Lterm.paneIDEnv] = String(id)
        if let socket = AppState.shared.socketPath { extra[Lterm.socketEnv] = socket }
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

    /// Starts copy mode. `onChange` runs on every move so the window can update its indicator.
    func beginCopyMode(onChange: @escaping () -> Void) {
        guard copyMode == nil else { return }
        let controller = CopyModeController(view: terminalView)
        controller.onChange = onChange
        controller.onEnd = { [weak self] in
            self?.copyMode = nil
            onChange()
        }
        copyMode = controller
        onChange()
    }

    /// Types a command into the shell and presses Return, so the pane stays open after it ends.
    /// The text waits until the shell has printed its prompt, so the terminal does not echo it twice.
    func type(command: String) {
        title = command
        owner?.paneTitleChanged(self)
        terminalView.whenQuiet { [weak self] in
            self?.send(text: command)
            self?.send(bytes: [0x0D])
        }
    }

    /// When the program last printed something.
    var lastOutput: Date { terminalView.lastOutput }

    var size: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
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

/// SwiftTerm's local process view, subclassed so lterm can track output for `pane wait --idle`.
final class LtermTerminalView: LocalProcessTerminalView {
    private(set) var lastOutput = Date()
    private var sawOutput = false
    private var quietActions: [() -> Void] = []
    private var quietTimer: Timer?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutput = Date()
        sawOutput = true
        super.dataReceived(slice: slice)
        if !quietActions.isEmpty { scheduleQuietCheck(after: 0.15) }
    }

    /// Runs `action` once the program has printed something and then gone quiet for a moment
    /// (a shell showing its first prompt). Gives up waiting after 3 seconds.
    func whenQuiet(_ action: @escaping () -> Void) {
        quietActions.append(action)
        scheduleQuietCheck(after: sawOutput ? 0.15 : 3)
    }

    private func scheduleQuietCheck(after delay: TimeInterval) {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runQuietActions() }
        }
    }

    private func runQuietActions() {
        let actions = quietActions
        quietActions.removeAll()
        for action in actions { action() }
    }
}
