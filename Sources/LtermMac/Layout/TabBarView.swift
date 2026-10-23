import SwiftUI

/// What the tab bar shows for one tab.
struct TabBarItem: Identifiable, Equatable {
    let id: Int
    var title: String
    /// Color of the dot for the tab's most urgent agent, nil for no dot.
    var dot: Color?
}

@MainActor
@Observable
final class TabBarModel {
    var items: [TabBarItem] = []
    var selected: Int = 0
    /// Extra text on the right, like agent counts or the leader indicator.
    var status: String = ""
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
}

/// The row of tabs at the top of a window.
struct TabBarView: View {
    let model: TabBarModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        TabButton(index: index, item: item, selected: index == model.selected,
                                  select: { model.onSelect?(index) }, close: { model.onClose?(index) })
                    }
                }
                .padding(.horizontal, 6)
            }
            Button(action: { model.onNew?() }) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New tab (Cmd+T)")
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 28)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1)))
    }
}

private struct TabButton: View {
    let index: Int
    let item: TabBarItem
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let dot = item.dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(index < 9 ? "\(index + 1) \(item.title)" : item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.white.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}
