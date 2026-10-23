import AppKit

/// One lterm window.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let pane: TerminalPane

    init() {
        pane = TerminalPane(id: 1)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "lterm"
        window.center()
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = pane.view
        pane.onExit = { [weak self] in self?.window?.close() }
        pane.start()
        window.makeFirstResponder(pane.terminalView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        pane.terminate()
        onClose?()
    }
}
