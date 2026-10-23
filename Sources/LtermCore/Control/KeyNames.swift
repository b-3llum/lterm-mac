import Foundation

/// Key names for `lterm pane keys`, turned into the bytes a terminal program receives.
public enum KeyNames {
    private static let named: [String: [UInt8]] = [
        "enter": [0x0D], "return": [0x0D],
        "esc": [0x1B], "escape": [0x1B],
        "tab": [0x09],
        "space": [0x20],
        "backspace": [0x7F], "bs": [0x7F],
        "up": Array("\u{1B}[A".utf8),
        "down": Array("\u{1B}[B".utf8),
        "right": Array("\u{1B}[C".utf8),
        "left": Array("\u{1B}[D".utf8),
        "home": Array("\u{1B}[H".utf8),
        "end": Array("\u{1B}[F".utf8),
        "pageup": Array("\u{1B}[5~".utf8),
        "pagedown": Array("\u{1B}[6~".utf8),
        "delete": Array("\u{1B}[3~".utf8), "del": Array("\u{1B}[3~".utf8),
        "shift-tab": Array("\u{1B}[Z".utf8),
        "f1": Array("\u{1B}OP".utf8), "f2": Array("\u{1B}OQ".utf8),
        "f3": Array("\u{1B}OR".utf8), "f4": Array("\u{1B}OS".utf8),
    ]

    /// All the names that `bytes(for:)` knows, for help text.
    public static let help = "enter esc tab space backspace up down left right home end pageup pagedown delete shift-tab f1-f4 ctrl-X alt-X (or a single character)"

    /// Bytes for a key name like "enter", "ctrl-c", "alt-b" or a single character. Nil if unknown.
    public static func bytes(for name: String) -> [UInt8]? {
        let lower = name.lowercased()
        if let bytes = named[lower] { return bytes }
        for prefix in ["ctrl-", "ctrl+", "c-"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            guard rest.count == 1, let scalar = rest.unicodeScalars.first else { return nil }
            switch scalar.value {
            case 97...122: return [UInt8(scalar.value - 96)]   // a-z
            case 64, 91, 92, 93, 94, 95: return [UInt8(scalar.value & 0x1F)]  // @ [ \ ] ^ _
            case 32: return [0]
            default: return nil
            }
        }
        for prefix in ["alt-", "alt+", "m-"] where lower.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard rest.count == 1 else { return nil }
            return [0x1B] + Array(rest.utf8)
        }
        if name.count == 1 { return Array(name.utf8) }
        return nil
    }
}
