import AppKit
import LtermCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: ControlServer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        KeyRouter.shared.install()
        startControlServer()
        openWindow(command: Self.launchCommand)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    /// `-e CMD` on the app's own command line (the CLI passes it when it starts the app).
    private static var launchCommand: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-e"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func startControlServer() {
        // The app's own environment may hold LTERM_SOCKET if it was started from inside lterm; ignore that.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: Lterm.socketEnv)
        let path = Lterm.socketPath(environment: env)
        let server = ControlServer(path: path) { request in
            await ControlHandler.handle(request)
        }
        do {
            try server.start()
            self.server = server
            AppState.shared.socketPath = path
            // `kill` or a logout sends SIGTERM: remove the socket before exiting.
            for number in [SIGTERM, SIGINT, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.server?.stop()
                    exit(0)
                }
                source.resume()
                signalSources.append(source)
            }
        } catch {
            NSLog("lterm: control socket failed at \(path): \(error)")
        }
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
