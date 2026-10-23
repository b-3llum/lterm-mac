import Foundation

/// What a coding agent in a pane is doing.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case working, blocked, done, idle
    /// No agent state (the pane is a plain shell, or the state was cleared).
    case none
}

/// The agent status of one pane.
public struct AgentStatus: Equatable, Sendable {
    public var state: AgentState
    /// Agent name, like "claude" or "codex".
    public var agent: String?
    /// What it is asking, or the notification text.
    public var message: String?
    /// True once the user has looked at the pane since it became done or got a notification.
    public var seen: Bool
    /// A desktop notification (OSC 9, 777 or 99) arrived and the user has not looked yet.
    public var notified: Bool

    public init(state: AgentState = .none, agent: String? = nil, message: String? = nil, seen: Bool = true, notified: Bool = false) {
        self.state = state
        self.agent = agent
        self.message = message
        self.seen = seen
        self.notified = notified
    }

    /// Higher is more urgent: blocked, then an unseen finish or notification, then working, then idle.
    public var urgency: Int {
        switch state {
        case .blocked: return 4
        case .done where !seen: return 3
        case _ where notified: return 3
        case .working: return 2
        case .done, .idle: return 1
        case .none: return 0
        }
    }

    /// True when the pane wants the user: blocked, finished and unseen, or notified and unseen.
    public var needsMe: Bool {
        state == .blocked || (state == .done && !seen) || notified
    }

    /// What the colored border should show, if anything.
    public var border: Border {
        if state == .blocked { return .blocked }
        if notified { return .blocked }
        switch state {
        case .working: return .working
        case .done: return seen ? .fadedDone : .done
        default: return .none
        }
    }

    public enum Border: Equatable, Sendable {
        case none, working, blocked, done
        /// Done and already looked at: the green border fades out.
        case fadedDone
    }

    /// Moves to a new state. Becoming done or blocked resets `seen` so the pane asks for attention.
    public mutating func update(state newState: AgentState, agent newAgent: String?, message newMessage: String?) {
        switch newState {
        case .blocked:
            // Every new question needs a look, even if it was already blocked.
            seen = false
        case .done:
            // A repeated "done" report does not make an already seen pane light up again.
            if state != .done { seen = false }
        case .working, .idle, .none:
            seen = true
        }
        state = newState
        if let newAgent { agent = newAgent }
        message = newMessage
        if newState == .none { agent = nil }
    }

    /// Short label for lists, like "working" or "blocked: Allow Bash?".
    public var label: String {
        var text = notified && state != .blocked ? "needs you" : state.rawValue
        if let message, !message.isEmpty { text += ": " + message }
        return text
    }
}

public enum AgentRules {
    /// The most urgent status from a list, or nil when none has an agent state or notification.
    public static func mostUrgent(_ statuses: [AgentStatus]) -> AgentStatus? {
        statuses.filter { $0.urgency > 0 }.max { $0.urgency < $1.urgency }
    }

    /// The next pane that needs the user. Blocked panes come first, then finished or notified ones.
    /// `panes` is every pane in display order. Repeated calls cycle through the candidates.
    public static func nextNeedsMe(panes: [(id: Int, status: AgentStatus)], current: Int?) -> Int? {
        let blocked = panes.filter { $0.status.state == .blocked }.map(\.id)
        let others = panes.filter { $0.status.needsMe && $0.status.state != .blocked }.map(\.id)
        let candidates = blocked + others
        guard !candidates.isEmpty else { return nil }
        if let current, let index = candidates.firstIndex(of: current) {
            return candidates[(index + 1) % candidates.count]
        }
        return candidates.first
    }

    /// Counts by state for the tab bar, like "2 working  1 blocked".
    public static func summary(_ statuses: [AgentStatus]) -> String {
        let order: [AgentState] = [.blocked, .done, .working, .idle]
        return order.compactMap { state in
            let count = statuses.filter { $0.state == state }.count
            return count > 0 ? "\(count) \(state.rawValue)" : nil
        }.joined(separator: "  ")
    }

    /// Text of a desktop notification from an OSC payload (the part after "9;", "777;" or "99;").
    /// Returns nil for payloads that are not notifications, such as OSC 9;4 progress reports.
    public static func notificationText(code: Int, payload: String) -> String? {
        switch code {
        case 9:
            // ConEmu uses OSC 9;<number>;... for progress and other commands.
            if let first = payload.split(separator: ";", maxSplits: 1).first, Int(first) != nil { return nil }
            return payload.trimmingCharacters(in: .whitespaces)
        case 777:
            let parts = payload.components(separatedBy: ";")
            guard parts.count >= 2, parts[0] == "notify" else { return nil }
            let title = parts[1]
            let body = parts.dropFirst(2).joined(separator: ";")
            return [title, body].filter { !$0.isEmpty }.joined(separator: ": ")
        case 99:
            // Kitty: OSC 99 ; metadata ; payload. e=1 means the payload is base64.
            guard let split = payload.firstIndex(of: ";") else { return nil }
            let metadata = payload[..<split]
            var body = String(payload[payload.index(after: split)...])
            if metadata.split(separator: ":").contains("e=1"), let data = Data(base64Encoded: body),
               let decoded = String(data: data, encoding: .utf8) {
                body = decoded
            }
            // Kitty also sends ?-queries and close requests with an empty body.
            return body.isEmpty || body == "?" ? nil : body
        default:
            return nil
        }
    }
}
