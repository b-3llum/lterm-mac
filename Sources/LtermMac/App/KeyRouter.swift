import AppKit
import LtermCore

/// Watches key presses before the terminal sees them, for the leader key and its follow-up key.
@MainActor
final class KeyRouter {
    static let shared = KeyRouter()

    private enum Mode {
        case normal
        case leader
        /// After H J K L the same keys keep resizing until another key or a short pause.
        case resize
    }

    private var mode = Mode.normal
    private var leader = LeaderSpec.ctrlSpace
    private var monitor: Any?
    private var resizeTimer: Timer?

    var leaderLabel: String { leader.label }
    var leaderSpec: LeaderSpec { leader }

    func install() {
        leader = Settings.leader
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func controller(for event: NSEvent) -> TerminalWindowController? {
        guard let window = event.window else { return nil }
        return AppState.shared.windows.first { $0.window === window }
    }

    /// Returns true when the event was used and must not reach the terminal.
    private func handle(_ event: NSEvent) -> Bool {
        guard let controller = controller(for: event) else { return false }
        if event.type == .leftMouseDown {
            controller.mouseDownInWindow(event)
            return false
        }
        // Let sheets and text fields (find bar, address bar) handle their own keys,
        // except the leader key itself.
        if !controller.terminalHasFocus && !leader.matches(event) && mode == .normal {
            return false
        }
        switch mode {
        case .normal:
            if leader.matches(event) {
                setMode(.leader, controller)
                return true
            }
            if event.modifierFlags.intersection([.control, .shift, .option, .command]) == [.control, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                controller.toggleSidebar()
                return true
            }
            return controller.interceptKey(event)
        case .leader:
            setMode(.normal, controller)
            if leader.matches(event) {
                // Leader twice sends the leader key itself to the program.
                controller.sendLeaderLiteral()
                return true
            }
            guard let key = Self.leaderKey(from: event), let action = LeaderKeymap.action(for: key) else {
                NSSound.beep()
                return true
            }
            if case .resize = action { setMode(.resize, controller) }
            controller.perform(action)
            return true
        case .resize:
            if let key = Self.leaderKey(from: event), case .resize? = LeaderKeymap.action(for: key) {
                controller.perform(LeaderKeymap.action(for: key)!)
                setMode(.resize, controller)
                return true
            }
            setMode(.normal, controller)
            return handle(event)
        }
    }

    private func setMode(_ newMode: Mode, _ controller: TerminalWindowController) {
        mode = newMode
        resizeTimer?.invalidate()
        resizeTimer = nil
        switch newMode {
        case .normal:
            controller.setKeyIndicator(nil)
        case .leader:
            controller.setKeyIndicator(leader.label)
        case .resize:
            controller.setKeyIndicator("resize: H J K L")
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self, weak controller] _ in
                MainActor.assumeIsolated {
                    guard let self, let controller, case .resize = self.mode else { return }
                    self.setMode(.normal, controller)
                }
            }
        }
    }

    static func leaderKey(from event: NSEvent) -> LeaderKey? {
        switch event.keyCode {
        case 53: return .escape
        case 123: return .arrow(.left)
        case 124: return .arrow(.right)
        case 125: return .arrow(.down)
        case 126: return .arrow(.up)
        default:
            guard let chars = event.characters, !chars.isEmpty else { return nil }
            return .character(chars)
        }
    }
}
