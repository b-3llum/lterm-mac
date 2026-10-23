import AppKit
import SwiftUI
import LtermCore

/// One lterm window: a tab bar and the panes of the selected tab.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [Tab] = []
    private(set) var currentIndex = 0
    private let tabBarModel = TabBarModel()
    private let container = PaneContainerView(frame: .zero)
    private var keyIndicator: String?
    private var isClosing = false

    var currentTab: Tab? { tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil }
    var focusedPane: Pane? { currentTab?.focusedPane }
    var focusedTerminal: TerminalPane? { focusedPane as? TerminalPane }

    /// Opens a window with one tab. `command` runs through the login shell instead of a plain shell.
    init(command: String? = nil, directory: String? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "lterm"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 220)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        super.init(window: window)
        window.delegate = self
        buildViews()
        positionWindow()
        newTab(command: command, directory: directory)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildViews() {
        guard let window else { return }
        let root = NSView()
        let tabBar = NSHostingView(rootView: TabBarView(model: tabBarModel))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        tabBarModel.onSelect = { [weak self] index in self?.selectTab(index) }
        tabBarModel.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBarModel.onNew = { [weak self] in self?.newTab() }
    }

    private func positionWindow() {
        guard let window else { return }
        if let last = AppState.shared.windows.last?.window {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            window.center()
        }
    }

    // MARK: Pane creation

    /// Makes a terminal pane that starts in `directory` (or the focused pane's directory).
    private func makeTerminal(command: String?, directory: String?) -> TerminalPane {
        let pane = TerminalPane(id: AppState.shared.allocatePaneID())
        pane.owner = self
        let cwd = directory ?? focusedTerminal?.currentDirectory
        pane.start(command: command, directory: cwd)
        return pane
    }

    @discardableResult
    func newTab(command: String? = nil, directory: String? = nil) -> TerminalPane {
        let pane = makeTerminal(command: command, directory: directory)
        addTab(with: pane)
        return pane
    }

    /// Adds a new tab holding `pane` and selects it.
    func addTab(with pane: Pane) {
        pane.owner = self
        let tab = Tab(id: AppState.shared.allocateTabID(), first: pane)
        tabs.append(tab)
        selectTab(tabs.count - 1)
    }

    @discardableResult
    func split(_ axis: SplitAxis, command: String? = nil, from target: Int? = nil) -> TerminalPane? {
        guard let tab = currentTab else { return nil }
        let directory = (target.flatMap { tab.panes[$0] } as? TerminalPane)?.currentDirectory
        let pane = makeTerminal(command: command, directory: directory)
        insert(pane, splitting: target ?? tab.focused, axis: axis, in: tab)
        return pane
    }

    /// Puts any pane next to `target` in `tab` and focuses it.
    func insert(_ pane: Pane, splitting target: Int, axis: SplitAxis, in tab: Tab) {
        pane.owner = self
        tab.zoomed = nil
        tab.add(pane)
        let anchor = tab.tree.contains(target) ? target : tab.focused
        tab.tree.split(anchor, axis: axis, newPane: pane.id)
        if tab === currentTab {
            focus(pane.id)
        } else {
            tab.focused = pane.id
        }
        updateTabBar()
    }

    // MARK: Closing

    /// Closes a pane in any tab of this window. The last pane closes its tab.
    func closePane(_ id: Int) {
        guard let tabIndex = tabs.firstIndex(where: { $0.panes[id] != nil }) else { return }
        let tab = tabs[tabIndex]
        guard let pane = tab.panes[id] else { return }
        if tab.tree.count == 1 {
            closeTab(at: tabIndex)
            return
        }
        // The pane that takes over the space gets focus: the one now covering the old center.
        let unit = Rect.unit
        let oldCenter = tab.tree.frames(in: unit)[id].map { ($0.midX, $0.midY) }
        tab.tree.remove(id)
        tab.forget(id)
        pane.close()
        if tab.focused == id {
            let frames = tab.tree.frames(in: unit)
            let heir = oldCenter.flatMap { center in
                frames.first { $0.value.minX <= center.0 && center.0 <= $0.value.maxX
                    && $0.value.minY <= center.1 && center.1 <= $0.value.maxY }?.key
            } ?? tab.tree.leaves.first!
            tab.focused = heir
        }
        if tab === currentTab {
            container.refresh()
            focus(tab.focused)
        }
        updateTabBar()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        for pane in tab.panes.values {
            pane.close()
        }
        for id in tab.panes.keys { tab.forget(id) }
        if tabs.isEmpty {
            window?.close()
            return
        }
        if currentIndex >= tabs.count || index < currentIndex {
            currentIndex = max(currentIndex - 1, 0)
        }
        selectTab(min(currentIndex, tabs.count - 1))
    }

    // MARK: Focus and tabs

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        currentIndex = index
        let tab = tabs[index]
        container.show(tab)
        focus(tab.focused)
        updateTabBar()
    }

    /// Focuses a pane of the current tab (or switches to its tab first).
    func focus(_ id: Int) {
        if let index = tabs.firstIndex(where: { $0.panes[id] != nil }), index != currentIndex {
            currentIndex = index
            container.show(tabs[index])
        }
        guard let tab = currentTab, let pane = tab.panes[id] else { return }
        if let zoomed = tab.zoomed, zoomed != id { tab.zoomed = nil }
        tab.focused = id
        container.refresh()
        window?.makeFirstResponder(pane.focusView)
        updateTitle()
        updateTabBar()
    }

    func moveFocus(_ direction: Direction) {
        guard let tab = currentTab, tab.zoomed == nil else { return }
        let rect = Rect(x: 0, y: 0, width: Double(container.bounds.width), height: Double(container.bounds.height))
        if let target = tab.tree.neighbor(of: tab.focused, direction: direction, in: rect) {
            focus(target)
        }
    }

    func resizeFocused(_ direction: Direction) {
        guard let tab = currentTab else { return }
        if tab.tree.resize(tab.focused, direction: direction, by: 0.05) {
            container.needsLayout = true
        } else {
            NSSound.beep()
        }
    }

    func toggleZoom() {
        guard let tab = currentTab, tab.tree.count > 1 else { return }
        tab.zoomed = tab.zoomed == nil ? tab.focused : nil
        container.refresh()
        focus(tab.focused)
    }

    /// True when a pane (not a text field or a sheet) has keyboard focus.
    var terminalHasFocus: Bool {
        guard let window, window.attachedSheet == nil, let responder = window.firstResponder as? NSView else { return false }
        return currentTab?.panes.values.contains { responder === $0.focusView || responder.isDescendant(of: $0.view) } ?? false
    }

    /// Clicking a pane focuses it.
    func mouseDownInWindow(_ event: NSEvent) {
        guard let tab = currentTab else { return }
        let point = container.convert(event.locationInWindow, from: nil)
        for (id, host) in tab.hosts where host.superview === container && host.frame.contains(point) {
            if id != tab.focused { focus(id) }
            return
        }
    }

    // MARK: Keys

    /// Hook for modes that take over the keyboard (copy mode). Returns true when the key was used.
    func interceptKey(_ event: NSEvent) -> Bool {
        false
    }

    func setKeyIndicator(_ text: String?) {
        keyIndicator = text
        updateTabBar()
    }

    /// Leader pressed twice: send the leader key itself (Ctrl+Space is NUL).
    func sendLeaderLiteral() {
        guard let terminal = focusedTerminal, let bytes = KeyRouter.shared.leaderSpec.literalBytes else { return }
        terminal.send(bytes: bytes)
    }

    func perform(_ action: LeaderAction) {
        switch action {
        case .splitRight: split(.horizontal)
        case .splitDown: split(.vertical)
        case .focus(let direction): moveFocus(direction)
        case .resize(let direction): resizeFocused(direction)
        case .nextPane:
            if let tab = currentTab, let next = tab.tree.next(after: tab.focused) { focus(next) }
        case .zoom: toggleZoom()
        case .closePane:
            if let id = currentTab?.focused { closePane(id) }
        case .newTab: newTab()
        case .nextTab: selectTab((currentIndex + 1) % max(tabs.count, 1))
        case .previousTab: selectTab((currentIndex + tabs.count - 1) % max(tabs.count, 1))
        case .goToTab(let number): selectTab(number - 1)
        case .closeTab: closeTab(at: currentIndex)
        case .search: showFind()
        case .help: showHelp()
        case .copyMode, .agentsSidebar, .nextNeedsMe, .detach:
            NSSound.beep()
        case .cancel:
            break
        }
    }

    private func showFind() {
        guard let terminal = focusedTerminal else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminal.terminalView.performTextFinderAction(item)
    }

    private func showHelp() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: HelpView(leader: KeyRouter.shared.leaderLabel) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated {
                if let id = self?.currentTab?.focused { self?.focus(id) }
            }
        }
    }

    // MARK: Fonts

    func changeFont(by delta: CGFloat?) {
        Settings.fontSize = delta.map { Settings.fontSize + $0 } ?? Settings.defaultFontSize
        let font = Settings.font
        for pane in AppState.shared.allTerminalPanes { pane.setFont(font) }
    }

    // MARK: Display

    func updateTitle() {
        window?.title = focusedPane?.title ?? "lterm"
    }

    func updateTabBar() {
        tabBarModel.items = tabs.map { TabBarItem(id: $0.id, title: $0.title, dot: nil) }
        tabBarModel.selected = currentIndex
        var status: [String] = []
        if let tab = currentTab, tab.zoomed != nil { status.append("zoom") }
        if let keyIndicator { status.append(keyIndicator) }
        tabBarModel.status = status.joined(separator: "  ")
    }

    // MARK: Menu actions

    @objc func newTabAction(_ sender: Any?) { newTab() }
    @objc func splitRightAction(_ sender: Any?) { split(.horizontal) }
    @objc func splitDownAction(_ sender: Any?) { split(.vertical) }
    @objc func zoomAction(_ sender: Any?) { toggleZoom() }
    @objc func closePaneAction(_ sender: Any?) { if let id = currentTab?.focused { closePane(id) } }
    @objc func closeTabAction(_ sender: Any?) { closeTab(at: currentIndex) }
    @objc func nextTabAction(_ sender: Any?) { perform(.nextTab) }
    @objc func previousTabAction(_ sender: Any?) { perform(.previousTab) }
    @objc func selectTabAction(_ sender: Any?) {
        if let item = sender as? NSMenuItem { selectTab(item.tag - 1) }
    }
    @objc func biggerFontAction(_ sender: Any?) { changeFont(by: 1) }
    @objc func smallerFontAction(_ sender: Any?) { changeFont(by: -1) }
    @objc func resetFontAction(_ sender: Any?) { changeFont(by: nil) }
    @objc func copyModeAction(_ sender: Any?) { perform(.copyMode) }
    @objc func helpAction(_ sender: Any?) { showHelp() }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        for tab in tabs {
            for pane in tab.panes.values { pane.close() }
        }
        tabs.removeAll()
        AppState.shared.remove(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = currentTab?.focused, let pane = currentTab?.panes[id] {
            window?.makeFirstResponder(pane.focusView)
        }
    }
}

extension TerminalWindowController: PaneOwner {
    func paneTitleChanged(_ pane: Pane) {
        if pane.id == focusedPane?.id { updateTitle() }
        updateTabBar()
    }

    func paneExited(_ pane: Pane) {
        closePane(pane.id)
    }
}
