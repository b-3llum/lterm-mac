import Foundation
import Darwin

/// Finds the user's login shell and builds the environment for child processes.
enum Shell {
    /// The login shell from the user database, falling back to $SHELL and then /bin/zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let cShell = pw.pointee.pw_shell {
            let shell = String(cString: cShell)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty { return env }
        return "/bin/zsh"
    }

    /// Environment for a pane, as "KEY=value" strings.
    static func environment(extra: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Variables that only make sense for the app process itself.
        for key in ["TERM_SESSION_ID", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "lterm"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
