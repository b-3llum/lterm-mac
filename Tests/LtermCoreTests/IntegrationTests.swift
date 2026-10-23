import XCTest
@testable import LtermCore

final class CodexConfigTests: XCTestCase {
    let lterm = "/Apps/lterm-mac.app/Contents/Resources/bin/lterm"

    func testInstallGoesBeforeFirstTable() throws {
        let toml = "model = \"o3\"\n\n[mcp_servers.x]\ncommand = \"y\"\n"
        let result = try CodexConfig.install(into: toml, lterm: lterm)
        let lines = result.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("notify = [\"\(lterm)\", \"pane\", \"state\", \"done\", \"--agent\", \"codex\"]"))
        XCTAssertTrue(result.contains("[mcp_servers.x]"))
        XCTAssertLessThan(result.range(of: "notify")!.lowerBound, result.range(of: "[mcp_servers")!.lowerBound)
        XCTAssertTrue(CodexConfig.isInstalled(result))
    }

    func testInstallIsIdempotentAndUpdatesPath() throws {
        let once = try CodexConfig.install(into: "", lterm: lterm)
        let twice = try CodexConfig.install(into: once, lterm: lterm)
        XCTAssertEqual(once, twice)
        let moved = try CodexConfig.install(into: once, lterm: "/new/lterm")
        XCTAssertTrue(moved.contains("/new/lterm"))
        XCTAssertFalse(moved.contains(lterm))
        XCTAssertEqual(moved.components(separatedBy: "notify").count, 2, "still one notify line")
    }

    func testRefusesToReplaceUserNotify() {
        let toml = "notify = [\"my-script\"]\n"
        XCTAssertThrowsError(try CodexConfig.install(into: toml, lterm: lterm)) { error in
            XCTAssertEqual(error as? CodexConfig.EditError, .existingNotify("notify = [\"my-script\"]"))
        }
        // A notify key inside a table is a different setting and is left alone.
        XCTAssertNoThrow(try CodexConfig.install(into: "[profiles.x]\nnotify = [\"a\"]\n", lterm: lterm))
    }

    func testUninstallRemovesOnlyOurLine() throws {
        let original = "model = \"o3\"\n"
        let installed = try CodexConfig.install(into: original, lterm: lterm)
        XCTAssertEqual(CodexConfig.uninstall(from: installed), original)
        XCTAssertFalse(CodexConfig.isInstalled(CodexConfig.uninstall(from: installed)))
    }
}

final class ClaudeHooksTests: XCTestCase {
    let lterm = "/Applications/lterm mac.app/Contents/Resources/bin/lterm"

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testInstallKeepsOtherSettingsAndHooks() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let result = ClaudeHooks.install(into: existing, lterm: lterm)
        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertEqual(commands(result, "Stop").count, 2)
        XCTAssertTrue(commands(result, "Stop").contains("say done"))
        XCTAssertTrue(commands(result, "Stop").contains { $0.hasPrefix("'\(lterm)' pane state done --agent claude") })
        XCTAssertTrue(commands(result, "PermissionRequest")[0].contains("blocked --agent claude --from-hook"))
        XCTAssertTrue(commands(result, "SessionEnd")[0].contains("none --agent claude --keep-done"))
        XCTAssertTrue(ClaudeHooks.isInstalled(result))
        let notification = (result["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]
        XCTAssertEqual(notification?.compactMap { $0["matcher"] as? String }, ["permission_prompt", "elicitation_dialog"])
    }

    func testInstallTwiceDoesNotDuplicate() {
        let once = ClaudeHooks.install(into: [:], lterm: lterm)
        let twice = ClaudeHooks.install(into: once, lterm: lterm)
        XCTAssertEqual(commands(twice, "Stop").count, 1)
        XCTAssertEqual(commands(twice, "UserPromptSubmit").count, 1)
    }

    func testUninstallRemovesOnlyOurs() {
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let removed = ClaudeHooks.uninstall(from: ClaudeHooks.install(into: existing, lterm: lterm))
        XCTAssertEqual(commands(removed, "Stop"), ["say done"])
        XCTAssertNil((removed["hooks"] as? [String: Any])?["UserPromptSubmit"])
        XCTAssertFalse(ClaudeHooks.isInstalled(removed))
        let clean = ClaudeHooks.uninstall(from: ClaudeHooks.install(into: [:], lterm: lterm))
        XCTAssertNil(clean["hooks"], "an empty hooks object is removed")
    }

    func testQuotesPathWithQuote() {
        let hook = ClaudeHooks.hooks.first { $0.event == "Stop" }!
        XCTAssertEqual(ClaudeHooks.command(for: hook, lterm: "/a'b/lterm"),
                       "'/a'\\''b/lterm' pane state done --agent claude # lterm-mac")
    }

    func testMessageFromHookInput() {
        func message(_ json: String) -> String? { ClaudeHooks.message(fromHookInput: Data(json.utf8)) }
        XCTAssertEqual(message(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#), "Allow Bash: rm -rf build?")
        XCTAssertEqual(message(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/y/main.swift"}}"#), "Allow Edit: main.swift?")
        XCTAssertEqual(message(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which DB?"}]}}"#), "Which DB?")
        XCTAssertEqual(message(#"{"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#),
                       "Claude needs your permission to use Bash")
        XCTAssertNil(message("not json"))
    }
}
