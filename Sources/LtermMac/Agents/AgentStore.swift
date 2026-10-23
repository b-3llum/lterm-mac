import AppKit
import SwiftUI
import LtermCore

/// One row of the agents sidebar.
struct AgentEntry: Identifiable, Equatable {
    let id: Int
    let tabNumber: Int
    let windowNumber: Int
    let title: String
    let status: AgentStatus
}

/// Agent state of every pane, shared by all windows.
@MainActor
@Observable
final class AgentStore {
    static let shared = AgentStore()

    private(set) var statuses: [Int: AgentStatus] = [:]
    /// Every pane in every window, for the sidebar. Rebuilt by `refreshEntries`.
    private(set) var entries: [AgentEntry] = []

    func status(of pane: Int) -> AgentStatus {
        statuses[pane] ?? AgentStatus()
    }

    /// Sets a pane's state, from `lterm pane state` or an agent hook.
    func set(pane: Int, state: AgentState, agent: String?, message: String?) {
        var status = self.status(of: pane)
        let before = status
        status.update(state: state, agent: agent, message: message)
        if state == .working { status.notified = false }
        // If the user is looking at the pane right now, a finish counts as seen (it shows, then fades).
        if state == .done && isWatched(pane) { status.seen = true }
        statuses[pane] = status
        let wantsAttention = (state == .done && before.state != .done) || state == .blocked
        if wantsAttention { bounceIfInBackground() }
        changed()
    }

    /// A program sent a desktop notification (OSC 9, 777 or 99).
    func notify(pane: Int, text: String) {
        var status = self.status(of: pane)
        if isWatched(pane) {
            return
        }
        status.notified = true
        if status.state != .blocked { status.message = text }
        statuses[pane] = status
        bounceIfInBackground()
        changed()
    }

    /// The user looked at the pane.
    func markSeen(pane: Int) {
        guard var status = statuses[pane], !status.seen || status.notified else { return }
        status.seen = true
        status.notified = false
        statuses[pane] = status
        changed()
    }

    func remove(pane: Int) {
        if statuses.removeValue(forKey: pane) != nil { changed() }
    }

    /// True when the pane is focused in the key window of the active app.
    private func isWatched(_ pane: Int) -> Bool {
        guard NSApp.isActive, let found = AppState.shared.locate(pane: pane) else { return false }
        return found.window.window?.isKeyWindow == true && found.window.currentTab === found.tab && found.tab.focused == pane
    }

    private func bounceIfInBackground() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func changed() {
        for window in AppState.shared.windows { window.agentsChanged() }
        refreshEntries()
    }

    /// Rebuilds the sidebar rows from the current windows and tabs.
    func refreshEntries() {
        var list: [AgentEntry] = []
        for (windowIndex, window) in AppState.shared.windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated() {
                for pane in tab.orderedPanes {
                    list.append(AgentEntry(id: pane.id, tabNumber: tabIndex + 1, windowNumber: windowIndex + 1,
                                           title: pane.title, status: status(of: pane.id)))
                }
            }
        }
        if list != entries { entries = list }
    }

    /// Every pane in display order with its status, for "next pane that needs me".
    var orderedStatuses: [(id: Int, status: AgentStatus)] {
        AppState.shared.windows.flatMap { $0.tabs }.flatMap { $0.tree.leaves }.map { ($0, status(of: $0)) }
    }
}

/// Colors for the agent states.
enum AgentColors {
    static let working = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.18, alpha: 1)
    static let blocked = NSColor(calibratedRed: 0.93, green: 0.30, blue: 0.27, alpha: 1)
    static let done = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.40, alpha: 1)
    static let idle = NSColor(calibratedWhite: 0.55, alpha: 1)

    static func color(for status: AgentStatus) -> NSColor? {
        if status.state == .blocked || status.notified { return blocked }
        switch status.state {
        case .working: return working
        case .done: return status.seen ? done.withAlphaComponent(0.5) : done
        case .idle: return idle
        case .blocked: return blocked
        case .none: return nil
        }
    }
}
