import AppKit
import LtermCore

/// Wraps one pane's view and draws the border around it (focus or agent state).
@MainActor
final class PaneHostView: NSView {
    let pane: Pane
    static let borderWidth: CGFloat = 2
    static let padding: CGFloat = 4

    var isFocused = false { didSet { if oldValue != isFocused { updateBorder() } } }
    /// Shown when the tab has more than one pane.
    var showsFocus = false { didSet { if oldValue != showsFocus { updateBorder() } } }
    /// Agent border. A change from done to fadedDone fades the green out.
    var agentBorder: AgentStatus.Border = .none {
        didSet { if oldValue != agentBorder { updateBorder(fade: oldValue == .done && agentBorder == .fadedDone) } }
    }

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = Self.borderWidth
        addSubview(pane.view)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Self.borderWidth + Self.padding
        pane.view.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    private var targetColor: NSColor {
        switch agentBorder {
        case .working: return AgentColors.working
        case .blocked: return AgentColors.blocked
        case .done: return AgentColors.done
        case .none, .fadedDone:
            return showsFocus && isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.55) : .clear
        }
    }

    private func updateBorder(fade: Bool = false) {
        guard let layer else { return }
        let color = targetColor.cgColor
        if fade {
            let animation = CABasicAnimation(keyPath: "borderColor")
            animation.fromValue = layer.presentation()?.borderColor ?? layer.borderColor
            animation.toValue = color
            animation.duration = 2.5
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(animation, forKey: "fade")
        } else {
            layer.removeAnimation(forKey: "fade")
        }
        layer.borderColor = color
    }
}

/// Lays out the panes of the current tab from its layout tree. Dividers can be dragged.
@MainActor
final class PaneContainerView: NSView {
    static let gap: CGFloat = 2
    private(set) var tab: Tab?
    var onLayoutChange: (() -> Void)?
    private var dragging: Divider?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a tab, swapping out the pane views of the previous one.
    func show(_ tab: Tab) {
        self.tab = tab
        refresh()
    }

    /// Re-syncs subviews and frames with the tab's tree.
    func refresh() {
        guard let tab else { return }
        let visible = Set(tab.zoomed.map { [$0] } ?? tab.tree.leaves)
        for sub in subviews {
            if let host = sub as? PaneHostView, visible.contains(host.pane.id), tab.hosts[host.pane.id] === host { continue }
            sub.removeFromSuperview()
        }
        for id in visible {
            if let host = tab.hosts[id], host.superview !== self { addSubview(host) }
        }
        for (id, host) in tab.hosts {
            host.isFocused = id == tab.focused
            host.showsFocus = tab.tree.count > 1 && tab.zoomed == nil
        }
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    private var bounds01: Rect {
        Rect(x: Double(bounds.minX), y: Double(bounds.minY), width: Double(bounds.width), height: Double(bounds.height))
    }

    override func layout() {
        super.layout()
        guard let tab else { return }
        if let zoomed = tab.zoomed, let host = tab.hosts[zoomed] {
            host.frame = bounds
            return
        }
        let frames = tab.tree.frames(in: bounds01, gap: Double(Self.gap))
        for (id, rect) in frames {
            tab.hosts[id]?.frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }

    // MARK: Divider dragging

    private var dividers: [Divider] {
        guard let tab, tab.zoomed == nil else { return [] }
        return tab.tree.dividers(in: bounds01, gap: Double(Self.gap))
    }

    private func hitRect(_ divider: Divider) -> NSRect {
        let r = NSRect(x: divider.rect.x, y: divider.rect.y, width: divider.rect.width, height: divider.rect.height)
        return divider.axis == .horizontal ? r.insetBy(dx: -4, dy: 0) : r.insetBy(dx: 0, dy: -4)
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(hitRect(divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    /// Lets clicks near a divider reach this view even when they land on the pane border.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dividers.contains(where: { hitRect($0).contains(local) }) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragging = dividers.first { hitRect($0).contains(point) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = dragging, let tab else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ratio: Double
        switch divider.axis {
        case .horizontal: ratio = (Double(point.x) - divider.parent.x) / max(divider.parent.width, 1)
        case .vertical: ratio = (Double(point.y) - divider.parent.y) / max(divider.parent.height, 1)
        }
        tab.tree.setRatio(at: divider.path, to: ratio)
        needsLayout = true
        // Keep the divider list in step with the new ratio for the rest of the drag.
        dragging = dividers.first { $0.path == divider.path }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil {
            dragging = nil
            window?.invalidateCursorRects(for: self)
            onLayoutChange?()
        }
    }
}
