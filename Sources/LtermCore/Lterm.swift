import Foundation

/// Shared names and paths used by both the app and the `lterm` CLI.
public enum Lterm {
    public static let bundleID = "com.b3llum.lterm-mac"
    public static let version = "0.1.0"

    /// Environment variable set inside every pane with that pane's id.
    public static let paneIDEnv = "LTERM_PANE_ID"
    /// Environment variable set inside every pane with the control socket path.
    public static let socketEnv = "LTERM_SOCKET"

    /// Folder for the socket and other runtime files.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("lterm-mac", isDirectory: true)
    }

    /// The control socket path: `$LTERM_SOCKET` if set, otherwise the default location.
    /// Values that are not absolute paths are ignored. The original lterm (Windows and Linux)
    /// uses the same variable for a TCP address, and both may be installed.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[socketEnv], path.hasPrefix("/") { return path }
        return supportDirectory.appendingPathComponent("lterm.sock").path
    }
}
