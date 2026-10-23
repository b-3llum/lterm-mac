import XCTest
@testable import LtermCore

final class CommandParserTests: XCTestCase {
    private let inPane = ["LTERM_PANE_ID": "7", "PWD": "/tmp/work"]

    private func request(_ argv: [String], env: [String: String] = [:]) throws -> (ControlRequest, OutputStyle) {
        guard case .request(let request, let style) = try CommandParser.parse(argv, environment: env) else {
            XCTFail("expected a request for \(argv)")
            throw ParseError("not a request")
        }
        return (request, style)
    }

    private func assertError(_ argv: [String], contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CommandParser.parse(argv, environment: inPane), file: file, line: line) { error in
            XCTAssertTrue((error as? ParseError)?.message.contains(text) == true, "\(error)", file: file, line: line)
        }
    }

    func testNoArgumentsOpensApp() throws {
        let (req, style) = try request([])
        XCTAssertEqual(req.cmd, "app.open")
        XCTAssertEqual(style, .none)
        XCTAssertEqual(try request(["-e", "htop"]).0.args["command"], "htop")
    }

    func testSplit() throws {
        let (req, style) = try request(["pane", "split", "--run", "claude 'fix it'", "--down"], env: inPane)
        XCTAssertEqual(req.cmd, "pane.split")
        XCTAssertEqual(req.args["run"], "claude 'fix it'")
        XCTAssertEqual(req.args["down"], true)
        XCTAssertEqual(req.caller, 7)
        XCTAssertEqual(style, .paneID)
        XCTAssertEqual(try request(["pane", "split", "--run=ls"]).0.args["run"], "ls")
        XCTAssertEqual(try request(["pane", "split", "--pane", "self"], env: inPane).0.args["pane"], 7)
    }

    func testListReadSend() throws {
        XCTAssertEqual(try request(["pane", "list"]).1, .paneList)
        XCTAssertEqual(try request(["pane", "list", "--json"]).1, .json)
        let (read, style) = try request(["pane", "read", "3", "--lines", "40"])
        XCTAssertEqual(read.args, ["id": 3, "lines": 40])
        XCTAssertEqual(style, .text)
        XCTAssertEqual(try request(["pane", "read", "3"]).0.args["lines"], 50, "default line count")
        let send = try request(["pane", "send", "3", "also", "run", "the", "linter"]).0
        XCTAssertEqual(send.args["text"], "also run the linter")
        XCTAssertEqual(send.args["enter"], true)
        XCTAssertEqual(try request(["pane", "send", "--no-enter", "3", "x"]).0.args["enter"], false)
        XCTAssertEqual(try request(["pane", "send", "3", "--", "--not-an-option"]).0.args["text"], "--not-an-option")
    }

    func testKeys() throws {
        let req = try request(["pane", "keys", "4", "esc", "ctrl-c", "enter"]).0
        XCTAssertEqual(req.args["keys"], .array(["esc", "ctrl-c", "enter"]))
        assertError(["pane", "keys", "4", "hyperspace"], contains: "unknown key")
        assertError(["pane", "keys", "4"], contains: "usage")
    }

    func testWait() throws {
        let (req, style) = try request(["pane", "wait", "5", "--state", "done,blocked", "--timeout", "30"])
        XCTAssertEqual(req.args["states"], .array(["done", "blocked"]))
        XCTAssertEqual(req.args["timeout"], .double(30))
        XCTAssertEqual(style, .state)
        XCTAssertEqual(try request(["pane", "wait", "5", "--idle", "5"]).0.args["idle"], .double(5))
        assertError(["pane", "wait", "5"], contains: "usage")
        assertError(["pane", "wait", "5", "--state", "sleeping"], contains: "unknown state")
        assertError(["pane", "wait", "--idle", "x", "5"], contains: "--idle")
    }

    func testState() throws {
        let req = try request(["pane", "state", "blocked", "--agent", "claude", "--message", "Allow Bash?"], env: inPane).0
        XCTAssertEqual(req.args, ["id": 7, "state": "blocked", "agent": "claude", "message": "Allow Bash?"])
        XCTAssertEqual(try CommandParser.parse(["pane", "state", "done"], environment: [:]), .noop,
                       "outside lterm the state command is a quiet no-op")
        XCTAssertEqual(try request(["pane", "state", "idle", "--pane", "2"]).0.args["id"], 2)
        assertError(["pane", "state", "sleepy"], contains: "usage")
        let codex = try request(["pane", "state", "done", "--agent", "codex", #"{"type":"agent-turn-complete"}"#], env: inPane).0
        XCTAssertEqual(codex.args["state"], "done", "the JSON payload Codex appends is ignored")
        assertError(["pane", "state", "done", "extra"], contains: "usage")
        XCTAssertEqual(try request(["pane", "state", "none", "--keep-done"], env: inPane).0.args["keepDone"], true)
        XCTAssertEqual(try CommandParser.parse(["install", "--force"]), .install(directory: nil, force: true))
    }

    func testCloseFocusAndIDs() throws {
        XCTAssertEqual(try request(["pane", "close", "9"]).0.args, ["id": 9])
        XCTAssertEqual(try request(["pane", "focus", "self"], env: inPane).0.args, ["id": 7])
        assertError(["pane", "close", "abc"], contains: "not a pane id")
        assertError(["pane", "close", "0"], contains: "not a pane id")
        XCTAssertThrowsError(try CommandParser.parse(["pane", "close", "self"], environment: [:]))
        assertError(["pane", "close", "1", "2"], contains: "unexpected argument")
        assertError(["pane", "read", "1", "--bogus"], contains: "unknown option")
        assertError(["pane", "explode"], contains: "unknown pane command")
    }

    func testOtherCommands() throws {
        let md = try request(["md", "notes.md"], env: inPane).0
        XCTAssertEqual(md.cmd, "md.open")
        XCTAssertEqual(md.args["path"], "/tmp/work/notes.md", "relative paths use the caller's folder")
        let attach = try request(["--attach", "me@box", "-s", "logs"]).0
        XCTAssertEqual(attach.cmd, "attach")
        XCTAssertEqual(attach.args, ["host": "me@box", "session": "logs"])
        XCTAssertEqual(try CommandParser.parse(["integration", "install", "claude"]), .integration(.install, "claude"))
        XCTAssertEqual(try CommandParser.parse(["integration"]), .integration(.status, nil))
        assertError(["integration", "install"], contains: "usage")
        assertError(["integration", "install", "vim"], contains: "unknown integration")
        XCTAssertEqual(try CommandParser.parse(["--version"]), .version)
        if case .help = try CommandParser.parse(["pane", "--help"]) {} else { XCTFail("pane --help") }
        if case .help = try CommandParser.parse(["pane", "read", "--help"]) {} else { XCTFail("pane read --help") }
        assertError(["frobnicate"], contains: "unknown command")
    }

    func testBrowse() throws {
        XCTAssertEqual(try request(["browse", "open", "localhost:3000"]).0.args["url"], "localhost:3000")
        XCTAssertEqual(try request(["browse", "click", "--text", "Sign in"]).0.args["text"], "Sign in")
        XCTAssertEqual(try request(["browse", "click", "#go"]).0.args["selector"], "#go")
        let at = try request(["browse", "click", "--at", "10", "20"]).0
        XCTAssertEqual(at.args["x"], .double(10))
        XCTAssertEqual(at.args["y"], .double(20))
        let type = try request(["browse", "type", "--selector", "#email", "ada@example.com", "--enter"]).0
        XCTAssertEqual(type.args, ["selector": "#email", "text": "ada@example.com", "enter": true])
        XCTAssertEqual(try request(["browse", "wait", "--text", "Welcome"]).0.args["text"], "Welcome")
        XCTAssertEqual(try request(["browse", "shot", "page.png"], env: inPane).0.args["path"], "/tmp/work/page.png")
        XCTAssertEqual(try request(["browse", "text", "--pane", "4"]).0.args, ["what": "body", "id": 4])
        assertError(["browse", "click"], contains: "usage")
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNames.bytes(for: "esc"), [27])
        XCTAssertEqual(KeyNames.bytes(for: "ctrl-c"), [3])
        XCTAssertEqual(KeyNames.bytes(for: "C-a"), [1])
        XCTAssertEqual(KeyNames.bytes(for: "alt-b"), [27, 98])
        XCTAssertEqual(KeyNames.bytes(for: "up"), [27, 91, 65])
        XCTAssertEqual(KeyNames.bytes(for: "q"), [113])
        XCTAssertNil(KeyNames.bytes(for: "ctrl-"))
        XCTAssertNil(KeyNames.bytes(for: "nope"))
    }

    func testCodecRoundTrip() throws {
        let request = ControlRequest(cmd: "pane.read", args: ["id": 3, "lines": 10, "x": .double(1.5), "list": .array([true, .null])], caller: 7)
        let data = try ControlCodec.encode(request)
        XCTAssertEqual(data.last, 0x0A, "one line per message")
        XCTAssertEqual(try ControlCodec.decode(ControlRequest.self, from: data), request)
        let response = ControlResponse.failure("no pane 3")
        XCTAssertEqual(try ControlCodec.decode(ControlResponse.self, from: try ControlCodec.encode(response)), response)
    }
}
