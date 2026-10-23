import AppKit

/// User preferences, stored in UserDefaults (`defaults write com.b3llum.lterm-mac KEY VALUE`).
@MainActor
enum Settings {
    static let defaultFontSize: CGFloat = 13
    private static let defaults = UserDefaults.standard

    static var fontSize: CGFloat {
        get {
            let value = defaults.double(forKey: "fontSize")
            return value > 0 ? CGFloat(value) : defaultFontSize
        }
        set { defaults.set(Double(min(max(newValue, 6), 48)), forKey: "fontSize") }
    }

    /// Font family, `fontName` default. Falls back to the system monospaced font.
    static var font: NSFont {
        if let name = defaults.string(forKey: "fontName"), let font = NSFont(name: name, size: fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// The leader key: `LTERM_LEADER` env var, then the `leader` default, then ctrl+space.
    static var leader: LeaderSpec {
        let text = ProcessInfo.processInfo.environment["LTERM_LEADER"] ?? defaults.string(forKey: "leader") ?? "ctrl+space"
        return LeaderSpec(parsing: text) ?? .ctrlSpace
    }
}

/// A key combination such as ctrl+space, ctrl+a, alt+space or f12.
struct LeaderSpec: Equatable {
    var modifiers: NSEvent.ModifierFlags
    /// Matched by key code for named keys (space, f-keys).
    var keyCode: UInt16?
    /// Matched against charactersIgnoringModifiers for letters.
    var character: String?
    var label: String

    static let ctrlSpace = LeaderSpec(modifiers: .control, keyCode: 49, character: nil, label: "Ctrl+Space")

    init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16?, character: String?, label: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.character = character
        self.label = label
    }

    init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        let fKeys: [String: UInt16] = ["f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
                                       "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]
        modifiers = mods
        if key == "space" {
            keyCode = 49
            character = nil
        } else if let code = fKeys[key] {
            keyCode = code
            character = nil
        } else if key.count == 1 {
            keyCode = nil
            character = key
        } else {
            return nil
        }
        let names = ["ctrl": "Ctrl", "control": "Ctrl", "alt": "Option", "opt": "Option", "option": "Option",
                     "cmd": "Cmd", "command": "Cmd", "shift": "Shift", "space": "Space"]
        label = parts.map { names[$0] ?? $0.uppercased() }.joined(separator: "+")
    }

    /// Bytes a program would get for this key, sent when the leader is pressed twice.
    var literalBytes: [UInt8]? {
        guard modifiers == .control else { return nil }
        if keyCode == 49 { return [0] }
        if let character, let ascii = character.unicodeScalars.first?.value, (97...122).contains(ascii) {
            return [UInt8(ascii - 96)]
        }
        return nil
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        guard event.modifierFlags.intersection(relevant) == modifiers else { return false }
        if let keyCode { return event.keyCode == keyCode }
        if let character { return event.charactersIgnoringModifiers?.lowercased() == character }
        return false
    }
}
