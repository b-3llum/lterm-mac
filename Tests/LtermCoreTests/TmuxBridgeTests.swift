import XCTest
@testable import LtermCore

final class TmuxBridgeTests: XCTestCase {
    func testSSHCommand() throws {
        let command = try TmuxBridge.sshCommand(host: "me@box.local", session: nil)
        XCTAssertTrue(command.hasPrefix("ssh -t 'me@box.local' '"))
        XCTAssertTrue(command.contains("exec tmux new-session -A -s lterm \\; set-option -q prefix2 C-]"))
        XCTAssertTrue(command.contains("tmux is not installed"))
        let remote = command.components(separatedBy: "'me@box.local' ")[1]
        XCTAssertTrue(remote.hasPrefix("'") && remote.hasSuffix("'"))
        XCTAssertFalse(remote.dropFirst().dropLast().contains("'"), "single quotes inside would end the quoted argument")
        XCTAssertTrue(try TmuxBridge.sshCommand(host: "box", session: "logs", ssh: "ssh -p 2222").hasPrefix("ssh -p 2222 -t 'box'"))
        XCTAssertTrue(try TmuxBridge.sshCommand(host: "box", session: "logs").contains("-s logs "))
    }

    func testRejectsUnsafeHostsAndNames() {
        XCTAssertThrowsError(try TmuxBridge.sshCommand(host: "box; rm -rf ~", session: nil))
        XCTAssertThrowsError(try TmuxBridge.sshCommand(host: "a'b", session: nil))
        XCTAssertThrowsError(try TmuxBridge.sshCommand(host: "", session: nil))
        XCTAssertThrowsError(try TmuxBridge.sshCommand(host: "box", session: "two words"))
    }

    func testLeaderKeysMapToTmux() {
        XCTAssertEqual(TmuxBridge.command(for: .splitRight), "split-window -h -c '#{pane_current_path}'")
        XCTAssertEqual(TmuxBridge.command(for: .focus(.left)), "select-pane -L")
        XCTAssertEqual(TmuxBridge.command(for: .resize(.down)), "resize-pane -D 5")
        XCTAssertEqual(TmuxBridge.command(for: .goToTab(3)), "select-window -t :3")
        XCTAssertEqual(TmuxBridge.command(for: .detach), "detach-client")
        XCTAssertNil(TmuxBridge.command(for: .agentsSidebar), "the sidebar stays an lterm feature")
        XCTAssertEqual(TmuxBridge.openPrompt, [0x1D, 58])
        XCTAssertEqual(TmuxBridge.promptInput(for: "kill-pane"), Array("kill-pane".utf8) + [13])
    }
}
