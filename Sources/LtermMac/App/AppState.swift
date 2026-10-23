import AppKit

/// App-wide registry of windows and pane ids.
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var windows: [TerminalWindowController] = []
    /// The control socket path once the server is listening.
    var socketPath: String?
    private var nextPaneID = 1
    private var nextTabID = 1

    func allocatePaneID() -> Int {
        defer { nextPaneID += 1 }
        return nextPaneID
    }

    func allocateTabID() -> Int {
        defer { nextTabID += 1 }
        return nextTabID
    }

    func add(_ window: TerminalWindowController) {
        windows.append(window)
    }

    func remove(_ window: TerminalWindowController) {
        windows.removeAll { $0 === window }
    }

    /// The window that has keyboard focus, or the frontmost lterm window.
    var activeWindow: TerminalWindowController? {
        if let key = NSApp.keyWindow, let match = windows.first(where: { $0.window === key }) { return match }
        if let main = NSApp.mainWindow, let match = windows.first(where: { $0.window === main }) { return match }
        return windows.last
    }

    /// Finds the window and tab holding a pane.
    func locate(pane id: Int) -> (window: TerminalWindowController, tab: Tab, pane: Pane)? {
        for window in windows {
            for tab in window.tabs {
                if let pane = tab.panes[id] { return (window, tab, pane) }
            }
        }
        return nil
    }

    /// Every terminal pane in every window, for app-wide changes like font size.
    var allTerminalPanes: [TerminalPane] {
        windows.flatMap { $0.tabs }.flatMap { $0.panes.values }.compactMap { $0 as? TerminalPane }
    }
}
