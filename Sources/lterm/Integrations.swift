import Foundation
import LtermCore

/// `lterm integration install|uninstall|status claude|codex`: edits the agents' config files.
/// Every file is backed up before it is changed.
enum Integrations {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static var home: String { environment["HOME"] ?? NSHomeDirectory() }

    static var claudeDirectory: String {
        environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath } ?? home + "/.claude"
    }

    static var codexDirectory: String {
        environment["CODEX_HOME"].map { ($0 as NSString).expandingTildeInPath } ?? home + "/.codex"
    }

    /// Config paths with symlinks resolved, so a settings file linked from a dotfiles repo stays a link.
    static var claudeSettings: String { (claudeDirectory + "/settings.json" as NSString).resolvingSymlinksInPath }
    static var claudeSkill: String { claudeDirectory + "/skills/lterm-mac-panes/SKILL.md" }
    static var codexConfig: String { (codexDirectory + "/config.toml" as NSString).resolvingSymlinksInPath }

    /// The file's text, "" when it does not exist yet. Fails (instead of guessing) when it cannot be read.
    static func readText(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw Failure("could not read \(path) as UTF-8 text, nothing was changed: \(error.localizedDescription)")
        }
    }

    static func run(_ action: IntegrationAction, target: String?, lterm: String) throws {
        switch (action, target) {
        case (.status, _):
            status(target)
        case (.install, "claude"):
            try installClaude(lterm: lterm)
        case (.uninstall, "claude"):
            try uninstallClaude()
        case (.install, "codex"):
            try installCodex(lterm: lterm)
        case (.uninstall, "codex"):
            try uninstallCodex()
        default:
            throw Failure("unknown integration")
        }
    }

    // MARK: Claude Code

    static func readClaudeSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: claudeSettings), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let settings = object as? [String: Any] else {
            throw Failure("\(claudeSettings) is not valid JSON. Fix it first, nothing was changed.")
        }
        return settings
    }

    static func writeClaudeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try write(data + Data("\n".utf8), to: claudeSettings)
    }

    static func installClaude(lterm: String) throws {
        let settings = try readClaudeSettings()
        try backup(claudeSettings)
        try writeClaudeSettings(ClaudeHooks.install(into: settings, lterm: lterm))
        try write(Data(skillText.utf8), to: claudeSkill)
        print("Claude Code: hooks added to \(claudeSettings)")
        print("Claude Code: skill added at \(claudeSkill)")
        warnIfTemporary(lterm)
        print("Restart Claude Code (or start a new session) to use them.")
    }

    static func uninstallClaude() throws {
        let settings = try readClaudeSettings()
        if ClaudeHooks.isInstalled(settings) {
            try backup(claudeSettings)
            try writeClaudeSettings(ClaudeHooks.uninstall(from: settings))
            print("Claude Code: hooks removed from \(claudeSettings)")
        } else {
            print("Claude Code: no lterm hooks in \(claudeSettings)")
        }
        let fm = FileManager.default
        if let text = try? String(contentsOfFile: claudeSkill, encoding: .utf8), text.contains(ClaudeHooks.marker) {
            try fm.removeItem(atPath: (claudeSkill as NSString).deletingLastPathComponent)
            print("Claude Code: skill removed")
        }
    }

    // MARK: Codex

    static func installCodex(lterm: String) throws {
        let current = try readText(codexConfig)
        let updated: String
        do {
            updated = try CodexConfig.install(into: current, lterm: lterm)
        } catch let error as CodexConfig.EditError {
            throw Failure(error.description)
        }
        try backup(codexConfig)
        try write(Data(updated.utf8), to: codexConfig)
        print("Codex: notify command added to \(codexConfig)")
        print("Codex only reports finished turns, so lterm shows it as done when a turn ends and as working when you press Return in its pane.")
        warnIfTemporary(lterm)
        print("Restart Codex to use it.")
    }

    static func uninstallCodex() throws {
        let current = try readText(codexConfig)
        guard CodexConfig.isInstalled(current) else {
            print("Codex: no lterm notify command in \(codexConfig)")
            return
        }
        try backup(codexConfig)
        try write(Data(CodexConfig.uninstall(from: current).utf8), to: codexConfig)
        print("Codex: notify command removed from \(codexConfig)")
    }

    // MARK: Status

    static func status(_ target: String?) {
        if target == nil || target == "claude" {
            let installed = (try? readClaudeSettings()).map(ClaudeHooks.isInstalled) ?? false
            let skill = FileManager.default.fileExists(atPath: claudeSkill)
            print("claude: \(installed ? "installed" : "not installed") (\(claudeSettings))\(skill ? ", skill installed" : "")")
        }
        if target == nil || target == "codex" {
            let text = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""
            print("codex:  \(CodexConfig.isInstalled(text) ? "installed" : "not installed") (\(codexConfig))")
        }
    }

    // MARK: Files

    /// Copies a file to FILE.lterm-backup-YYYYMMDD-HHMMSS next to it. Missing files need no backup.
    static func backup(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Never overwrite an older backup: add -2, -3, ... when one with this name exists.
        let base = path + ".lterm-backup-" + formatter.string(from: Date())
        var target = base
        var number = 2
        while FileManager.default.fileExists(atPath: target) {
            target = "\(base)-\(number)"
            number += 1
        }
        try FileManager.default.copyItem(atPath: path, toPath: target)
        print("backup: \(target)")
    }

    static func write(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let oldPermissions = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // An atomic write makes a new file: give it back the old permissions (or rw-r--r--).
        try fm.setAttributes([.posixPermissions: oldPermissions ?? 0o644], ofItemAtPath: path)
    }

    static func warnIfTemporary(_ lterm: String) {
        if lterm.contains("/DerivedData/") || lterm.contains("/.build/") {
            print("note: the hooks point at a build folder (\(lterm)).")
            print("      Move lterm-mac.app to /Applications and run this again so they keep working.")
        }
    }

    /// The Claude Code skill that teaches it to use lterm panes.
    static let skillText = """
    ---
    name: lterm-mac-panes
    description: Run other coding agents or long commands in separate lterm-mac panes and coordinate them. Use when running inside lterm-mac (the LTERM_PANE_ID environment variable is set) and the user asks for work split across several agents, for helpers in split panes, or for something to run in its own pane.
    ---
    <!-- \(ClaudeHooks.marker) -->

    # Working with lterm-mac panes

    You are running inside lterm-mac, a terminal with splits. `$LTERM_PANE_ID` is your own pane.
    The `lterm` command controls panes:

    ```
    id=$(lterm pane split --run "claude 'task text'")   # new pane next to yours, prints its id
    lterm pane wait $id --state done,blocked --timeout 1800   # until it finishes or needs someone
    lterm pane wait $id --idle 5               # or until it printed nothing for 5 seconds
    lterm pane read $id --lines 80             # the last 80 lines of its screen
    lterm pane send $id "more instructions"    # type a line and press Enter
    lterm pane keys $id esc                    # press keys: enter, esc, up, ctrl-c, ...
    lterm pane list                            # all panes with their agent state
    lterm pane close $id
    ```

    How to run helpers:

    1. Write each helper's task to a file (for example `.lterm/task-1.md`) with the goal, the files it may
       change, and where to write its result (for example `.lterm/result-1.md`).
    2. Start each helper with `lterm pane split --run "claude 'Read .lterm/task-1.md and do it'"`.
       Use `--down` for a vertical stack. Keep the ids.
    3. Wait with `lterm pane wait ID --state done,blocked`. It prints the state.
    4. If a helper is `blocked`, it is waiting on a permission prompt or a question. Do not answer
       permission prompts for it. Tell the user which pane needs them (`lterm pane list` shows the
       question) and wait again.
    5. When it is `done`, read its result file (or `lterm pane read ID`) and review the work.
    6. Close helper panes you no longer need with `lterm pane close ID`.

    Browser panes for checking web pages:

    ```
    lterm browse open http://localhost:3000    # prints the pane id
    lterm browse wait --text "Welcome"
    lterm browse click --text "Sign in"
    lterm browse type --selector "#email" ada@example.com --enter
    lterm browse text main
    lterm browse shot page.png                 # then look at page.png
    ```
    """
}
