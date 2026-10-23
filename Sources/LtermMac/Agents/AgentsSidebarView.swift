import SwiftUI
import LtermCore

/// The agents sidebar: every pane with its agent and state. Click a row to go there.
struct AgentsSidebarView: View {
    let store: AgentStore
    let select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                Text(AgentRules.summary(store.entries.map(\.status)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        Row(entry: entry, showWindow: Set(store.entries.map(\.windowNumber)).count > 1)
                            .contentShape(Rectangle())
                            .onTapGesture { select(entry.id) }
                    }
                }
                .padding(6)
            }
            Spacer(minLength: 0)
            Text("Ctrl+Space u: next that needs you")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 1)))
    }

    private struct Row: View {
        let entry: AgentEntry
        let showWindow: Bool
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(AgentColors.color(for: entry.status).map { Color(nsColor: $0) } ?? Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.status.agent ?? entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(showWindow ? "w\(entry.windowNumber) t\(entry.tabNumber) #\(entry.id)" : "tab \(entry.tabNumber) #\(entry.id)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.status.state == .none && !entry.status.notified ? "no agent" : entry.status.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.08) : Color.clear))
            .onHover { hovering = $0 }
        }
    }
}
