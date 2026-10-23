import Foundation

/// Edits ~/.codex/config.toml so Codex runs `lterm pane state done` when it finishes a turn.
/// Codex's `notify` setting is a top-level key, so it must come before the first [table].
public enum CodexConfig {
    /// Marks the line lterm wrote, so uninstall only removes our own line.
    public static let marker = "# added by lterm-mac"

    public enum EditError: Error, Equatable, CustomStringConvertible {
        /// The user already has their own notify command. We do not overwrite it.
        case existingNotify(String)

        public var description: String {
            switch self {
            case .existingNotify(let line):
                return "config.toml already has its own notify setting (\(line)). lterm will not replace it. " +
                    "Remove it, or call `lterm pane state done --agent codex` from your notify script."
            }
        }
    }

    static func notifyLine(lterm: String) -> String {
        let parts = [lterm, "pane", "state", "done", "--agent", "codex"].map { "\"\(escape($0))\"" }
        return "notify = [\(parts.joined(separator: ", "))] \(marker)"
    }

    /// Returns the config with our notify line added (or updated if we added it before).
    public static func install(into toml: String, lterm: String) throws -> String {
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        let ours = notifyLine(lterm: lterm)
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        for index in 0..<firstTable {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("notify") else { continue }
            let afterKey = trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            if trimmed.contains(marker) {
                lines[index] = ours
                return lines.joined(separator: "\n")
            }
            throw EditError.existingNotify(trimmed)
        }
        lines.insert(ours, at: 0)
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Returns the config without our notify line.
    public static func uninstall(from toml: String) -> String {
        toml.components(separatedBy: "\n").filter { !$0.contains(marker) }.joined(separator: "\n")
    }

    public static func isInstalled(_ toml: String) -> Bool {
        toml.contains(marker)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
