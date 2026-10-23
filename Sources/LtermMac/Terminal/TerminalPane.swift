import AppKit
import SwiftTerm

/// A pane running a process (by default the login shell) inside SwiftTerm.
@MainActor
final class TerminalPane: NSObject {
    let id: Int
    let terminalView: LtermTerminalView
    var view: NSView { terminalView }
    var title = "shell"
    var onExit: (() -> Void)?

    init(id: Int) {
        self.id = id
        terminalView = LtermTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminalView.processDelegate = self
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// Starts the login shell (or `command` through the shell when given).
    func start(command: String? = nil, directory: String? = nil) {
        let shell = Shell.loginShell
        let shellName = (shell as NSString).lastPathComponent
        let env = Shell.environment(extra: ["LTERM_PANE_ID": String(id)])
        var args: [String] = []
        if let command { args = ["-l", "-c", command] }
        terminalView.startProcess(
            executable: shell,
            args: args,
            environment: env,
            execName: command == nil ? "-" + shellName : shellName,
            currentDirectory: directory ?? NSHomeDirectory()
        )
    }

    func terminate() {
        if terminalView.process.running { terminalView.terminate() }
    }
}

extension TerminalPane: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        source.window?.title = title.isEmpty ? "lterm" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?()
    }
}

/// SwiftTerm's local process view, subclassed so lterm can hook output and keys.
final class LtermTerminalView: LocalProcessTerminalView {}
