import Foundation

/// SSH sessions with a persistent tmux session on the server, and the lterm keys that drive it.
public enum TmuxBridge {
    /// A second tmux prefix set only on lterm's session, so lterm can reach tmux's command prompt
    /// without knowing the user's own prefix. Ctrl+] is byte 0x1D.
    public static let prefixKey = "C-]"
    public static let prefixByte: UInt8 = 0x1D

    public struct InvalidArgument: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Default session name, like the original lterm's.
    public static let defaultSession = "lterm"

    /// The local shell command that connects. `ssh` may be replaced with `$LTERM_SSH` (for example "ssh -p 2222").
    public static func sshCommand(host: String, session: String?, ssh: String? = nil) throws -> String {
        guard !host.isEmpty, host.allSatisfy({ !$0.isWhitespace && !"'\"\\;|&$`<>(){}".contains($0) }) else {
            throw InvalidArgument(description: "'\(host)' is not a valid host. Put ssh options in LTERM_SSH instead.")
        }
        let name = session ?? defaultSession
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw InvalidArgument(description: "session names can only use letters, numbers, - and _")
        }
        // Runs in the server's shell. `\;` reaches tmux as a command separator.
        let remote = "command -v tmux >/dev/null 2>&1 || { echo \"lterm: tmux is not installed on this server\"; exit 3; }; "
            + "exec tmux new-session -A -s \(name) \\; set-option -q prefix2 \(prefixKey)"
        let sshPart = (ssh?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "ssh"
        // The remote part is wrapped in single quotes, so it must not contain any itself.
        assert(!remote.contains("'"))
        return "\(sshPart) -t '\(host)' '\(remote)'"
    }

    /// The tmux command for a leader key in an attached pane, or nil when lterm handles the key itself.
    public static func command(for action: LeaderAction) -> String? {
        switch action {
        case .splitRight: return "split-window -h -c '#{pane_current_path}'"
        case .splitDown: return "split-window -v -c '#{pane_current_path}'"
        case .focus(let direction): return "select-pane -\(flag(direction))"
        case .resize(let direction): return "resize-pane -\(flag(direction)) 5"
        case .nextPane: return "select-pane -t :.+"
        case .zoom: return "resize-pane -Z"
        case .closePane: return "kill-pane"
        case .newTab: return "new-window -c '#{pane_current_path}'"
        case .nextTab: return "next-window"
        case .previousTab: return "previous-window"
        case .goToTab(let number): return "select-window -t :\(number)"
        case .closeTab: return "kill-window"
        case .copyMode: return "copy-mode"
        case .search: return "copy-mode \\; send-keys -X search-backward-incremental ''"
        case .detach: return "detach-client"
        case .agentsSidebar, .nextNeedsMe, .help, .reconnect, .cancel: return nil
        }
    }

    /// Bytes that open tmux's command prompt: the lterm prefix, then ':'.
    public static let openPrompt: [UInt8] = [prefixByte] + Array(":".utf8)

    /// Bytes to type into the open prompt: the command and Return.
    /// Send these a moment after `openPrompt`: tmux opens the prompt from its command queue,
    /// so bytes that arrive in the same burst would still go to the program in the pane.
    public static func promptInput(for command: String) -> [UInt8] {
        Array(command.utf8) + [0x0D]
    }

    /// How long to wait between `openPrompt` and `promptInput`.
    public static let promptDelay = 0.12

    private static func flag(_ direction: Direction) -> String {
        switch direction {
        case .left: return "L"
        case .right: return "R"
        case .up: return "U"
        case .down: return "D"
        }
    }
}
