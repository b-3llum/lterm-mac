import Foundation

/// What a key does after the leader key (Ctrl+Space by default).
public enum LeaderAction: Equatable, Sendable {
    case splitRight, splitDown
    case focus(Direction)
    case resize(Direction)
    case nextPane, zoom, closePane
    case newTab, nextTab, previousTab, closeTab
    case goToTab(Int)
    case copyMode, search, agentsSidebar, nextNeedsMe, help, detach, reconnect
    case cancel
}

/// A key pressed after the leader.
public enum LeaderKey: Equatable, Sendable {
    case character(String)
    case arrow(Direction)
    case escape
}

public enum LeaderKeymap {
    /// Maps the key pressed after the leader to an action, or nil for unknown keys.
    public static func action(for key: LeaderKey) -> LeaderAction? {
        switch key {
        case .escape:
            return .cancel
        case .arrow(let direction):
            return .focus(direction)
        case .character(let text):
            switch text {
            case "v": return .splitRight
            case "s": return .splitDown
            case "h": return .focus(.left)
            case "j": return .focus(.down)
            case "k": return .focus(.up)
            case "l": return .focus(.right)
            case "H": return .resize(.left)
            case "J": return .resize(.down)
            case "K": return .resize(.up)
            case "L": return .resize(.right)
            case "o": return .nextPane
            case "z": return .zoom
            case "x": return .closePane
            case "t": return .newTab
            case "n": return .nextTab
            case "p": return .previousTab
            case "w": return .closeTab
            case "c": return .copyMode
            case "/": return .search
            case "a": return .agentsSidebar
            case "u": return .nextNeedsMe
            case "?": return .help
            case "d": return .detach
            case "r": return .reconnect
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                return .goToTab(Int(text)!)
            default:
                return nil
            }
        }
    }

    /// Lines for the help screen.
    public static let helpLines: [(String, String)] = [
        ("v / s", "split right / down"),
        ("h j k l, arrows", "move between panes"),
        ("H J K L", "resize (tap again to repeat)"),
        ("o", "next pane"),
        ("z", "zoom pane / restore"),
        ("x", "close pane"),
        ("t", "new tab"),
        ("n / p", "next / previous tab"),
        ("1 to 9", "go to tab"),
        ("w", "close tab"),
        ("c", "copy mode"),
        ("/", "search scrollback"),
        ("a", "agents sidebar"),
        ("u", "next agent that needs you"),
        ("d / r", "detach / reconnect (ssh sessions)"),
        ("?", "this help"),
    ]
}
