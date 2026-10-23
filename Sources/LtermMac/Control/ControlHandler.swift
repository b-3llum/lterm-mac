import AppKit
import LtermCore

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Carries out control socket requests on the main actor.
@MainActor
enum ControlHandler {
    static func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return .success(try await run(request))
        } catch let error as ControlError {
            return .failure(error.message)
        } catch {
            return .failure("\(error)")
        }
    }

    private static func run(_ request: ControlRequest) async throws -> JSONValue {
        let args = request.args
        switch request.cmd {
        case "app.open":
            (NSApp.delegate as? AppDelegate)?.openWindow(command: args["command"]?.string)
            NSApp.activate(ignoringOtherApps: true)
            return .null
        case "pane.split":
            return try split(request)
        case "pane.list":
            return .array(listPanes())
        case "pane.read":
            let pane = try find(args["id"])
            return ["text": .string(pane.readText(lines: args["lines"]?.int ?? 50))]
        case "pane.send":
            let pane = try terminal(args["id"])
            pane.send(text: args["text"]?.string ?? "")
            if args["enter"]?.bool ?? true { pane.send(bytes: [0x0D]) }
            return .null
        case "pane.keys":
            let pane = try terminal(args["id"])
            for key in args["keys"]?.array ?? [] {
                guard let name = key.string, let bytes = KeyNames.bytes(for: name) else {
                    throw ControlError("unknown key \(key.string ?? "?")")
                }
                pane.send(bytes: bytes)
            }
            return .null
        case "pane.wait":
            return try await wait(args)
        case "pane.close":
            let found = try locate(args["id"])
            found.window.closePane(found.pane.id)
            return .null
        case "pane.focus":
            let found = try locate(args["id"])
            found.window.jump(to: found.pane.id)
            return .null
        case "pane.state":
            let found = try locate(args["id"])
            guard let name = args["state"]?.string, let state = AgentState(rawValue: name) else {
                throw ControlError("unknown state")
            }
            if args["keepDone"]?.bool == true && AgentStore.shared.status(of: found.pane.id).state == .done {
                return .null
            }
            AgentStore.shared.set(pane: found.pane.id, state: state, agent: args["agent"]?.string, message: args["message"]?.string)
            return .null
        default:
            throw ControlError("unknown command '\(request.cmd)'. This app may be older than the lterm tool.")
        }
    }

    // MARK: Lookups

    private static func locate(_ value: JSONValue?) throws -> (window: TerminalWindowController, tab: Tab, pane: Pane) {
        guard let id = value?.int else { throw ControlError("missing pane id") }
        guard let found = AppState.shared.locate(pane: id) else { throw ControlError("no pane \(id)") }
        return found
    }

    private static func find(_ value: JSONValue?) throws -> Pane {
        try locate(value).pane
    }

    private static func terminal(_ value: JSONValue?) throws -> TerminalPane {
        let pane = try find(value)
        guard let terminal = pane as? TerminalPane else { throw ControlError("pane \(pane.id) is a \(pane.kind) pane, not a terminal") }
        return terminal
    }

    /// The pane a new split goes next to: --pane, else the caller's pane, else the focused pane.
    static func targetPane(_ request: ControlRequest) -> (window: TerminalWindowController, tab: Tab, pane: Pane)? {
        if let id = request.args["pane"]?.int ?? request.caller, let found = AppState.shared.locate(pane: id) {
            return found
        }
        guard let window = AppState.shared.activeWindow, let tab = window.currentTab, let pane = tab.focusedPane else { return nil }
        return (window, tab, pane)
    }

    // MARK: Commands

    private static func split(_ request: ControlRequest) throws -> JSONValue {
        let args = request.args
        let run = args["run"]?.string
        if let id = args["pane"]?.int, AppState.shared.locate(pane: id) == nil { throw ControlError("no pane \(id)") }
        guard let target = targetPane(request) else {
            // No window at all: open one, the command goes in its first pane.
            let window = (NSApp.delegate as! AppDelegate).openWindow()
            guard let pane = window.focusedTerminal else { throw ControlError("could not open a window") }
            if let run { pane.type(command: run) }
            return ["id": .int(pane.id)]
        }
        // Splits asked for by a program in a pane keep focus where the user is typing, unless --focus.
        let focus = args["focus"]?.bool ?? (request.caller == nil)
        let axis: SplitAxis = args["down"]?.bool == true ? .vertical : .horizontal
        let pane = target.window.splitPane(target.pane.id, axis: axis, run: run, focus: focus)
        return ["id": .int(pane.id)]
    }

    static func listPanes() -> [JSONValue] {
        var result: [JSONValue] = []
        let active = AppState.shared.activeWindow
        for (windowIndex, window) in AppState.shared.windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated() {
                for pane in tab.orderedPanes {
                    let status = AgentStore.shared.status(of: pane.id)
                    var item: [String: JSONValue] = [
                        "id": .int(pane.id),
                        "window": .int(windowIndex + 1),
                        "tab": .int(tabIndex + 1),
                        "kind": .string(pane.kind),
                        "title": .string(pane.title),
                        "state": .string(status.notified && status.state == .none ? "notified" : status.state.rawValue),
                        "focused": .bool(window === active && tab === window.currentTab && tab.focused == pane.id),
                    ]
                    if let agent = status.agent { item["agent"] = .string(agent) }
                    if let message = status.message { item["message"] = .string(message) }
                    if let terminal = pane as? TerminalPane {
                        let size = terminal.size
                        item["cols"] = .int(size.cols)
                        item["rows"] = .int(size.rows)
                    }
                    result.append(.object(item))
                }
            }
        }
        return result
    }

    /// Waits for an agent state or for quiet output. Polls every 100 ms on the main actor.
    private static func wait(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard let id = args["id"]?.int else { throw ControlError("missing pane id") }
        guard AppState.shared.locate(pane: id) != nil else { throw ControlError("no pane \(id)") }
        let states = Set((args["states"]?.array ?? []).compactMap { $0.string }.compactMap(AgentState.init(rawValue:)))
        let idle = args["idle"]?.double
        let deadline = args["timeout"]?.double.map { Date().addingTimeInterval($0) }
        while true {
            guard let found = AppState.shared.locate(pane: id) else { throw ControlError("pane \(id) was closed") }
            let state = AgentStore.shared.status(of: id).state
            if !states.isEmpty && states.contains(state) {
                return ["state": .string(state.rawValue), "timedOut": false]
            }
            if idle != nil && !(found.pane is TerminalPane) { throw ControlError("--idle only works on terminal panes") }
            if let idle, let terminal = found.pane as? TerminalPane, Date().timeIntervalSince(terminal.lastOutput) >= idle {
                return ["state": .string(state.rawValue), "idle": .double(Date().timeIntervalSince(terminal.lastOutput)), "timedOut": false]
            }
            if let deadline, Date() >= deadline {
                return ["state": .string(state.rawValue), "timedOut": true]
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
