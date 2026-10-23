import Foundation

/// How the CLI prints a result.
public enum OutputStyle: Equatable, Sendable {
    /// Print nothing.
    case none
    /// Print `result.id` (for commands that create a pane).
    case paneID
    /// Print `result.text` as is.
    case text
    /// Print `result` (an array of panes) as a table.
    case paneList
    /// Print `result` as JSON.
    case json
    /// Print `result.state` (for `pane wait`).
    case state
}

public enum IntegrationAction: String, Equatable, Sendable {
    case install, uninstall, status
}

/// What the CLI should do, decided from argv alone.
public enum ParsedCommand: Equatable, Sendable {
    /// Send a request to the app and print the result.
    case request(ControlRequest, OutputStyle)
    /// Nothing to do (for example `pane state` outside lterm), exit 0.
    case noop
    case help(String)
    case version
    /// Add, remove or show agent hooks. Target is "claude", "codex" or nil for all.
    case integration(IntegrationAction, String?)
    /// Print an image inline (iTerm2 protocol). Width is in terminal cells.
    case image(path: String, width: Int?)
    /// Link the CLI into a folder on PATH.
    case install(directory: String?, force: Bool)
}

public struct ParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Turns `lterm` arguments into a `ParsedCommand`. Pure, so it can be unit tested.
public enum CommandParser {
    public static func parse(_ argv: [String], environment: [String: String] = [:]) throws -> ParsedCommand {
        let caller = environment[Lterm.paneIDEnv].flatMap { Int($0) }
        var args = ArgScanner(argv)

        if args.isEmpty {
            return .request(ControlRequest(cmd: "app.open", caller: caller), .none)
        }
        if args.peek == "-h" || args.peek == "--help" || args.peek == "help" {
            return .help(Usage.main)
        }
        if args.peek == "--version" || args.peek == "-V" || args.peek == "version" {
            return .version
        }
        if let command = try args.value("-e", "--exec") {
            try args.expectEmpty()
            return .request(ControlRequest(cmd: "app.open", args: ["command": .string(command)], caller: caller), .none)
        }
        if let host = try args.value("--attach") {
            let session = try args.value("-s", "--session")
            try args.expectEmpty()
            var request = ControlRequest(cmd: "attach", args: ["host": .string(host)], caller: caller)
            if let session { request.args["session"] = .string(session) }
            if let ssh = environment["LTERM_SSH"], !ssh.isEmpty { request.args["ssh"] = .string(ssh) }
            return .request(request, .paneID)
        }

        let command = args.next()!
        switch command {
        case "pane":
            return try parsePane(&args, caller: caller)
        case "md":
            if args.wantsHelp { return .help(Usage.md) }
            let split = args.flag("--split")
            guard let file = try args.positionals().first else { throw ParseError("usage: lterm md FILE") }
            let path = Self.absolute(file, cwd: environment["PWD"])
            return .request(ControlRequest(cmd: "md.open", args: ["path": .string(path), "split": .bool(split)], caller: caller), .paneID)
        case "browse":
            return try parseBrowse(&args, caller: caller, environment: environment)
        case "integration":
            if args.wantsHelp { return .help(Usage.integration) }
            let rest = try args.positionals()
            guard let first = rest.first else { return .integration(.status, nil) }
            guard let action = IntegrationAction(rawValue: first) else {
                throw ParseError("unknown integration action '\(first)'. Use install, uninstall or status.")
            }
            let target = rest.dropFirst().first
            if let target, target != "claude", target != "codex" {
                throw ParseError("unknown integration '\(target)'. Use claude or codex.")
            }
            if action != .status && target == nil {
                throw ParseError("usage: lterm integration \(action.rawValue) claude|codex")
            }
            return .integration(action, target)
        case "install":
            let directory = try args.value("--dir")
            let force = args.flag("--force")
            try args.expectEmpty()
            return .install(directory: directory, force: force)
        case "keys":
            return .help(Usage.keys)
        case "img", "image":
            let width = try args.value("--width", "-w").map { try positiveInt($0, "--width") }
            guard let file = try args.positionals().first else { throw ParseError("usage: lterm img FILE [--width CELLS]") }
            return .image(path: absolute(file, cwd: environment["PWD"]), width: width)
        default:
            throw ParseError("unknown command '\(command)'. Run 'lterm --help'.")
        }
    }

    // MARK: pane

    private static func parsePane(_ args: inout ArgScanner, caller: Int?) throws -> ParsedCommand {
        guard let sub = args.next(), sub != "--help", sub != "-h", sub != "help" else { return .help(Usage.pane) }
        if args.wantsHelp { return .help(Usage.pane) }
        func request(_ cmd: String, _ values: [String: JSONValue] = [:]) -> ControlRequest {
            ControlRequest(cmd: cmd, args: values, caller: caller)
        }
        switch sub {
        case "split":
            var values: [String: JSONValue] = [:]
            if let run = try args.value("--run", "-r") { values["run"] = .string(run) }
            if args.flag("--down", "-d") { values["down"] = true }
            if args.flag("--right") { values["down"] = false }
            if args.flag("--focus") { values["focus"] = true }
            if let target = try args.value("--pane", "-p") { values["pane"] = .int(try paneID(target, caller: caller)) }
            try args.expectEmpty()
            return .request(request("pane.split", values), .paneID)
        case "list", "ls":
            let json = args.flag("--json")
            try args.expectEmpty()
            return .request(request("pane.list"), json ? .json : .paneList)
        case "read":
            let lines = try args.value("--lines", "-n").map { try positiveInt($0, "--lines") } ?? 50
            let id = try requirePane(&args, caller: caller, usage: "lterm pane read ID [--lines N]")
            try args.expectEmpty()
            return .request(request("pane.read", ["id": .int(id), "lines": .int(lines)]), .text)
        case "send":
            let noEnter = args.flag("--no-enter")
            var rest = try args.positionals()
            guard rest.count >= 2 else { throw ParseError("usage: lterm pane send ID TEXT") }
            let id = try paneID(rest.removeFirst(), caller: caller)
            let text = rest.joined(separator: " ")
            return .request(request("pane.send", ["id": .int(id), "text": .string(text), "enter": .bool(!noEnter)]), .none)
        case "keys":
            var rest = try args.positionals()
            guard rest.count >= 2 else { throw ParseError("usage: lterm pane keys ID KEY... (keys: \(KeyNames.help))") }
            let id = try paneID(rest.removeFirst(), caller: caller)
            for key in rest where KeyNames.bytes(for: key) == nil {
                throw ParseError("unknown key '\(key)'. Keys: \(KeyNames.help)")
            }
            return .request(request("pane.keys", ["id": .int(id), "keys": .array(rest.map { .string($0) })]), .none)
        case "wait":
            var values: [String: JSONValue] = [:]
            if let states = try args.value("--state") {
                let list = states.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !list.isEmpty else { throw ParseError("--state needs a list like done,blocked") }
                for state in list where AgentState(rawValue: state) == nil {
                    throw ParseError("unknown state '\(state)'. Use working, blocked, done, idle or none.")
                }
                values["states"] = .array(list.map { .string($0) })
            }
            if let idle = try args.value("--idle") { values["idle"] = .double(try positiveNumber(idle, "--idle")) }
            if let timeout = try args.value("--timeout", "-t") { values["timeout"] = .double(try positiveNumber(timeout, "--timeout")) }
            guard values["states"] != nil || values["idle"] != nil else {
                throw ParseError("usage: lterm pane wait ID --state done,blocked | --idle SECONDS [--timeout SECONDS]")
            }
            let id = try requirePane(&args, caller: caller, usage: "lterm pane wait ID --state LIST | --idle S")
            try args.expectEmpty()
            values["id"] = .int(id)
            return .request(request("pane.wait", values), .state)
        case "close":
            let id = try requirePane(&args, caller: caller, usage: "lterm pane close ID")
            try args.expectEmpty()
            return .request(request("pane.close", ["id": .int(id)]), .none)
        case "focus":
            let id = try requirePane(&args, caller: caller, usage: "lterm pane focus ID")
            try args.expectEmpty()
            return .request(request("pane.focus", ["id": .int(id)]), .none)
        case "state":
            let agent = try args.value("--agent", "-a")
            let message = try args.value("--message", "-m")
            let fromHook = args.flag("--from-hook")
            let keepDone = args.flag("--keep-done")
            let target = try args.value("--pane", "-p")
            var rest = try args.positionals()
            // Codex's `notify` command appends a JSON payload as the last argument. Ignore it.
            if rest.count == 2, rest[1].hasPrefix("{") { rest.removeLast() }
            guard rest.count == 1, let state = AgentState(rawValue: rest[0]) else {
                throw ParseError("usage: lterm pane state working|blocked|done|idle|none [--agent NAME] [--message TEXT]")
            }
            guard let id = try target.map({ try paneID($0, caller: caller) }) ?? caller else {
                // Not inside an lterm pane: nothing to report. Exit quietly so hooks never fail.
                return .noop
            }
            var values: [String: JSONValue] = ["id": .int(id), "state": .string(state.rawValue)]
            if let agent { values["agent"] = .string(agent) }
            if let message { values["message"] = .string(message) }
            // The CLI reads the hook's stdin JSON and turns this into a message before sending.
            if fromHook { values["fromHook"] = true }
            // Leave a finished pane showing "done" (used when an agent session ends right after its turn).
            if keepDone { values["keepDone"] = true }
            return .request(request("pane.state", values), .none)
        default:
            throw ParseError("unknown pane command '\(sub)'. Run 'lterm pane --help'.")
        }
    }

    // MARK: browse

    private static func parseBrowse(_ args: inout ArgScanner, caller: Int?, environment: [String: String]) throws -> ParsedCommand {
        guard let sub = args.next(), sub != "--help", sub != "-h", sub != "help" else { return .help(Usage.browse) }
        if args.wantsHelp { return .help(Usage.browse) }
        var values: [String: JSONValue] = [:]
        if let pane = try args.value("--pane", "-p") { values["id"] = .int(try paneID(pane, caller: caller)) }
        func request(_ cmd: String, _ style: OutputStyle) -> ParsedCommand {
            .request(ControlRequest(cmd: cmd, args: values, caller: caller), style)
        }
        switch sub {
        case "open":
            if args.flag("--down", "-d") { values["down"] = true }
            if args.flag("--tab") { values["tab"] = true }
            guard let url = try args.positionals().first else { throw ParseError("usage: lterm browse open URL") }
            values["url"] = .string(url)
            return request("browse.open", .paneID)
        case "go", "navigate":
            guard let url = try args.positionals().first else { throw ParseError("usage: lterm browse go URL") }
            values["url"] = .string(url)
            return request("browse.go", .none)
        case "click":
            if let text = try args.value("--text") { values["text"] = .string(text) }
            if let selector = try args.value("--selector", "-s") { values["selector"] = .string(selector) }
            if let x = try args.value("--at") {
                let rest = try args.positionals()
                guard let xValue = Double(x), let yText = rest.first, let yValue = Double(yText) else {
                    throw ParseError("usage: lterm browse click --at X Y")
                }
                values["x"] = .double(xValue)
                values["y"] = .double(yValue)
            } else if let selector = try args.positionals().first {
                values["selector"] = .string(selector)
            }
            guard values["text"] != nil || values["selector"] != nil || values["x"] != nil else {
                throw ParseError("usage: lterm browse click SELECTOR | --text TEXT | --at X Y")
            }
            return request("browse.click", .none)
        case "type":
            let enter = args.flag("--enter")
            let selector = try args.value("--selector", "-s")
            let rest = try args.positionals()
            guard !rest.isEmpty else { throw ParseError("usage: lterm browse type [--selector CSS] TEXT [--enter]") }
            if let selector { values["selector"] = .string(selector) }
            values["text"] = .string(rest.joined(separator: " "))
            values["enter"] = .bool(enter)
            return request("browse.type", .none)
        case "wait":
            if let text = try args.value("--text") { values["text"] = .string(text) }
            if let selector = try args.value("--selector", "-s") { values["selector"] = .string(selector) }
            if let timeout = try args.value("--timeout", "-t") { values["timeout"] = .double(try positiveNumber(timeout, "--timeout")) }
            if values["text"] == nil && values["selector"] == nil, let selector = try args.positionals().first {
                values["selector"] = .string(selector)
            }
            guard values["text"] != nil || values["selector"] != nil else {
                throw ParseError("usage: lterm browse wait --text TEXT | --selector CSS [--timeout S]")
            }
            return request("browse.wait", .none)
        case "text":
            let what = try args.positionals().first ?? "body"
            values["what"] = .string(what)
            return request("browse.text", .text)
        case "eval", "js":
            let code = try args.positionals().joined(separator: " ")
            guard !code.isEmpty else { throw ParseError("usage: lterm browse eval JAVASCRIPT") }
            values["code"] = .string(code)
            return request("browse.eval", .text)
        case "shot", "screenshot":
            let file = try args.positionals().first ?? "screenshot.png"
            values["path"] = .string(absolute(file, cwd: environment["PWD"]))
            return request("browse.shot", .text)
        case "back", "forward", "reload":
            try args.expectEmpty()
            return request("browse." + sub, .none)
        case "url":
            return request("browse.url", .text)
        default:
            throw ParseError("unknown browse command '\(sub)'. Run 'lterm browse --help'.")
        }
    }

    // MARK: Helpers

    /// A pane id: a number, or "self" / "." for the pane the CLI runs in.
    static func paneID(_ text: String, caller: Int?) throws -> Int {
        if text == "self" || text == "." {
            guard let caller else { throw ParseError("'\(text)' only works inside an lterm pane") }
            return caller
        }
        guard let id = Int(text), id > 0 else { throw ParseError("'\(text)' is not a pane id") }
        return id
    }

    private static func requirePane(_ args: inout ArgScanner, caller: Int?, usage: String) throws -> Int {
        guard let first = args.next() else { throw ParseError("usage: \(usage)") }
        return try paneID(first, caller: caller)
    }

    private static func positiveInt(_ text: String, _ name: String) throws -> Int {
        guard let value = Int(text), value > 0 else { throw ParseError("\(name) needs a positive number") }
        return value
    }

    private static func positiveNumber(_ text: String, _ name: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value >= 0, value <= 31_536_000 else {
            throw ParseError("\(name) needs a number of seconds (up to one year)")
        }
        return value
    }

    static func absolute(_ path: String, cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || path.contains("://") { return expanded }
        let base = cwd ?? FileManager.default.currentDirectoryPath
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

/// A tiny argv reader: options can be `--name value` or `--name=value`, `--` ends options.
struct ArgScanner {
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    var isEmpty: Bool { items.isEmpty }
    var peek: String? { items.first }
    var wantsHelp: Bool { optionArea.contains("--help") || optionArea.contains("-h") }

    /// Items before a "--" separator.
    private var optionArea: ArraySlice<String> {
        items.firstIndex(of: "--").map { items[..<$0] } ?? items[...]
    }

    mutating func next() -> String? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func flag(_ names: String...) -> Bool {
        let limit = items.firstIndex(of: "--") ?? items.count
        guard let index = items[..<limit].firstIndex(where: { names.contains($0) }) else { return false }
        items.remove(at: index)
        return true
    }

    mutating func value(_ names: String...) throws -> String? {
        let limit = items.firstIndex(of: "--") ?? items.count
        for index in 0..<limit {
            let item = items[index]
            if names.contains(item) {
                guard index + 1 < items.count, items[index + 1] != "--" else {
                    throw ParseError("\(item) needs a value")
                }
                let value = items[index + 1]
                items.removeSubrange(index...(index + 1))
                return value
            }
            for name in names where name.hasPrefix("--") && item.hasPrefix(name + "=") {
                items.remove(at: index)
                return String(item.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// The remaining plain arguments. Unknown options are an error (put them after `--` to pass them on).
    mutating func positionals() throws -> [String] {
        var result: [String] = []
        var afterSeparator = false
        for item in items {
            if !afterSeparator && item == "--" {
                afterSeparator = true
                continue
            }
            if !afterSeparator && item.hasPrefix("-") && item.count > 1 && Double(item) == nil {
                throw ParseError("unknown option '\(item)'")
            }
            result.append(item)
        }
        items.removeAll()
        return result
    }

    mutating func expectEmpty() throws {
        let rest = try positionals()
        if let extra = rest.first { throw ParseError("unexpected argument '\(extra)'") }
    }
}
