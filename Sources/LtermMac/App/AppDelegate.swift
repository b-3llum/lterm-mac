import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        KeyRouter.shared.install()
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.activeWindow?.markFocusedSeen()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Opens a new window and returns it.
    @discardableResult
    func openWindow(command: String? = nil, directory: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(command: command, directory: directory)
        AppState.shared.add(controller)
        controller.showWindow(nil)
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }
}
