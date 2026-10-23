import Foundation
import LtermCore

/// Makes sure the bundled `lterm` wins on PATH inside panes, even when the user's startup files
/// put another `lterm` (like the original Rust one) first. zsh only, like kitty and Ghostty do it:
/// zsh starts with ZDOTDIR pointing at our folder, our .zshenv puts the user's ZDOTDIR back and
/// sources their .zshenv, and a one-time precmd hook moves our bin folder to the front of PATH
/// after all their files have run.
@MainActor
enum ShellIntegration {
    static var folder: String {
        (Lterm.supportDirectory.path as NSString).appendingPathComponent("zsh")
    }

    private static let zshenv = """
    # Written by lterm-mac. Loads your own zsh files, then puts lterm-mac's bin folder first on PATH.
    if [[ -n "$LTERM_ORIG_ZDOTDIR" ]]; then
      ZDOTDIR="$LTERM_ORIG_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    unset LTERM_ORIG_ZDOTDIR
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -n "$LTERM_BIN" ]]; then
      _lterm_mac_path() {
        path=("$LTERM_BIN" ${path:#$LTERM_BIN})
        precmd_functions=(${precmd_functions:#_lterm_mac_path})
        unfunction _lterm_mac_path
      }
      precmd_functions+=(_lterm_mac_path)
    fi

    """

    /// Writes the zsh file (once per launch) and returns the extra environment for a pane.
    static func environment(shell: String, currentEnvironment: [String: String]) -> [String: String] {
        guard (shell as NSString).lastPathComponent == "zsh", let resources = Bundle.main.resourcePath else { return [:] }
        guard UserDefaults.standard.object(forKey: "shellIntegration") as? Bool ?? true else { return [:] }
        guard writeFiles() else { return [:] }
        var extra = ["ZDOTDIR": folder, "LTERM_BIN": resources + "/bin"]
        if let original = currentEnvironment["ZDOTDIR"], !original.isEmpty {
            extra["LTERM_ORIG_ZDOTDIR"] = original
        }
        return extra
    }

    private static var written = false

    private static func writeFiles() -> Bool {
        if written { return true }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try zshenv.write(toFile: (folder as NSString).appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            written = true
        } catch {
            NSLog("lterm: could not write zsh integration: \(error)")
        }
        return written
    }
}
