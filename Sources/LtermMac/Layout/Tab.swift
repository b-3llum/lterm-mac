import AppKit
import LtermCore

/// One tab: a layout tree plus the panes in it.
@MainActor
final class Tab {
    let id: Int
    var tree: LayoutTree
    private(set) var panes: [Int: Pane] = [:]
    private(set) var hosts: [Int: PaneHostView] = [:]
    var focused: Int
    var zoomed: Int?

    init(id: Int, first pane: Pane) {
        self.id = id
        tree = LayoutTree(pane: pane.id)
        focused = pane.id
        add(pane)
    }

    var focusedPane: Pane? { panes[focused] }
    var title: String { focusedPane?.title ?? "lterm" }

    /// Registers a pane with this tab (the tree is updated by the caller).
    func add(_ pane: Pane) {
        panes[pane.id] = pane
        hosts[pane.id] = PaneHostView(pane: pane)
    }

    /// Forgets a pane. The caller removes it from the tree.
    func forget(_ id: Int) {
        panes.removeValue(forKey: id)
        hosts[id]?.removeFromSuperview()
        hosts.removeValue(forKey: id)
        if zoomed == id { zoomed = nil }
    }

    /// Panes in reading order.
    var orderedPanes: [Pane] { tree.leaves.compactMap { panes[$0] } }
}
