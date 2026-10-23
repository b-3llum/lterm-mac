import Foundation

/// Adds and removes the lterm hooks in Claude Code's settings.json (`~/.claude/settings.json`).
/// Works on the parsed JSON object so it can be tested without touching files.
public enum ClaudeHooks {
    /// Every hook command lterm writes ends with this shell comment, so uninstall finds only ours.
    public static let marker = "# lterm-mac"

    public struct Hook: Equatable, Sendable {
        public var event: String
        public var matcher: String?
        public var state: String
        /// Read the hook's stdin JSON for a message (the permission or question being asked).
        public var fromHook: Bool
        /// Do not clear a "done" state (SessionEnd right after Stop, as with `claude -p`).
        public var keepDone = false
    }

    /// Which Claude Code events report which state.
    public static let hooks: [Hook] = [
        Hook(event: "SessionStart", matcher: nil, state: "idle", fromHook: false),
        Hook(event: "UserPromptSubmit", matcher: nil, state: "working", fromHook: false),
        Hook(event: "PostToolUse", matcher: nil, state: "working", fromHook: false),
        Hook(event: "PreToolUse", matcher: "AskUserQuestion", state: "blocked", fromHook: true),
        Hook(event: "PermissionRequest", matcher: nil, state: "blocked", fromHook: true),
        Hook(event: "Notification", matcher: "permission_prompt", state: "blocked", fromHook: true),
        Hook(event: "Notification", matcher: "elicitation_dialog", state: "blocked", fromHook: true),
        Hook(event: "Stop", matcher: nil, state: "done", fromHook: false),
        Hook(event: "SessionEnd", matcher: nil, state: "none", fromHook: false, keepDone: true),
    ]

    /// The shell command for one hook. The path is single-quoted so spaces are safe.
    public static func command(for hook: Hook, lterm: String) -> String {
        let quoted = "'" + lterm.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var parts = [quoted, "pane", "state", hook.state, "--agent", "claude"]
        if hook.fromHook { parts.append("--from-hook") }
        if hook.keepDone { parts.append("--keep-done") }
        return parts.joined(separator: " ") + " " + marker
    }

    /// Returns settings with lterm's hooks added. Old lterm hooks are replaced, other hooks are kept.
    public static func install(into settings: [String: Any], lterm: String) -> [String: Any] {
        var result = uninstall(from: settings)
        var allHooks = result["hooks"] as? [String: Any] ?? [:]
        for hook in hooks {
            var groups = allHooks[hook.event] as? [Any] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command(for: hook, lterm: lterm), "timeout": 10] as [String: Any]],
            ]
            if let matcher = hook.matcher { group["matcher"] = matcher }
            groups.append(group)
            allHooks[hook.event] = groups
        }
        result["hooks"] = allHooks
        return result
    }

    /// Returns settings without lterm's hooks. Empty groups and events left behind are removed.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var allHooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, value) in allHooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for item in groups {
                guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else {
                    kept.append(item)
                    continue
                }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.isEmpty && !entries.isEmpty { continue }
                group["hooks"] = remaining
                kept.append(group)
            }
            if kept.isEmpty { allHooks.removeValue(forKey: event) } else { allHooks[event] = kept }
        }
        if allHooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = allHooks }
        return result
    }

    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        guard let allHooks = settings["hooks"] as? [String: Any] else { return false }
        return allHooks.values.contains { value in
            (value as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOurs)
            }
        }
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.hasSuffix(marker) == true
    }

    /// The message to show for a blocked pane, from the JSON Claude Code passes to a hook on stdin.
    public static func message(fromHookInput data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tool = object["tool_name"] as? String {
            let input = object["tool_input"] as? [String: Any]
            if tool == "AskUserQuestion" {
                let questions = input?["questions"] as? [[String: Any]]
                if let first = questions?.first?["question"] as? String { return first }
                return "has a question"
            }
            if let command = input?["command"] as? String { return "Allow \(tool): \(shorten(command))?" }
            if let path = input?["file_path"] as? String { return "Allow \(tool): \((path as NSString).lastPathComponent)?" }
            return "Allow \(tool)?"
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        return nil
    }

    private static func shorten(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(57)) + "..." : line
    }
}
