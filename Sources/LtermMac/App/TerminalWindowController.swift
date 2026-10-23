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
    private var sidebarWidth: NSLayoutConstraint?
    private var sidebarView: NSView?
    private(set) var sidebarVisible = false

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
        let sidebar = NSHostingView(rootView: AgentsSidebarView(store: AgentStore.shared) { [weak self] id in
            self?.jump(to: id)
        })
        for view in [tabBar, container, sidebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let width = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidth = width
        sidebarView = sidebar
        sidebar.isHidden = true
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            width,
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

    /// Splits a pane in any tab of this window for the control socket. `run` is typed into the new shell.
    /// With `focus` false the keyboard stays where it was.
    func splitPane(_ target: Int, axis: SplitAxis, run: String?, focus shouldFocus: Bool) -> TerminalPane {
        let tab = tabs.first { $0.panes[target] != nil } ?? currentTab!
        let directory = (tab.panes[target] as? TerminalPane)?.currentDirectory
        let pane = makeTerminal(command: nil, directory: directory)
        let previous = tab.focused
        insert(pane, splitting: target, axis: axis, in: tab)
        if !shouldFocus {
            if tab === currentTab { focus(previous) } else { tab.focused = previous }
        }
        if let run { pane.type(command: run) }
        return pane
    }

    /// Shows a Markdown file in a new tab, or split next to the focused pane.
    @discardableResult
    func openMarkdown(_ url: URL, split: Bool, next target: Int? = nil) -> MarkdownPane {
        let pane = MarkdownPane(id: AppState.shared.allocatePaneID(), fileURL: url)
        if split, let tab = tabs.first(where: { $0.panes[target ?? -1] != nil }) ?? currentTab {
            insert(pane, splitting: target ?? tab.focused, axis: .horizontal, in: tab)
        } else {
            addTab(with: pane)
        }
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
        AgentStore.shared.remove(pane: id)
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
            AgentStore.shared.remove(pane: pane.id)
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
        markFocusedSeen()
        updateTitle()
        updateTabBar()
    }

    /// The focused pane counts as looked at when this window is key and the app is active.
    func markFocusedSeen() {
        guard NSApp.isActive, window?.isKeyWindow == true, let id = currentTab?.focused else { return }
        AgentStore.shared.markSeen(pane: id)
    }

    /// Focuses a pane in any window, bringing that window to the front.
    func jump(to id: Int) {
        guard let found = AppState.shared.locate(pane: id) else { return }
        found.window.window?.makeKeyAndOrderFront(nil)
        found.window.focus(id)
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        sidebarWidth?.constant = sidebarVisible ? 260 : 0
        sidebarView?.isHidden = !sidebarVisible
        AgentStore.shared.refreshEntries()
    }

    /// Ctrl+Space u: blocked panes first, then finished or notified ones, across all windows.
    func jumpToNextNeedsMe() {
        let current = AppState.shared.activeWindow?.currentTab?.focused
        guard let next = AgentRules.nextNeedsMe(panes: AgentStore.shared.orderedStatuses, current: current) else {
            NSSound.beep()
            return
        }
        jump(to: next)
    }

    /// Agent states changed: refresh borders and the tab bar.
    func agentsChanged() {
        for tab in tabs {
            for (id, host) in tab.hosts {
                host.agentBorder = AgentStore.shared.status(of: id).border
            }
        }
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
        if let markdown = focusedPane as? MarkdownPane { return markdown.handleKey(event) }
        guard let copyMode = focusedTerminal?.copyMode else { return false }
        // Let Cmd shortcuts (Cmd+C, Cmd+W, ...) still reach the menu.
        if event.modifierFlags.contains(.command) { return false }
        copyMode.handle(event)
        return true
    }

    func startCopyMode() {
        guard let terminal = focusedTerminal else { return NSSound.beep() }
        terminal.beginCopyMode { [weak self] in self?.updateTabBar() }
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
        case .copyMode: startCopyMode()
        case .agentsSidebar: toggleSidebar()
        case .nextNeedsMe: jumpToNextNeedsMe()
        case .detach:
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
        let store = AgentStore.shared
        tabBarModel.items = tabs.map { tab in
            let urgent = AgentRules.mostUrgent(tab.tree.leaves.map { store.status(of: $0) })
            let dot = urgent.flatMap { AgentColors.color(for: $0) }.map { Color(nsColor: $0) }
            return TabBarItem(id: tab.id, title: tab.title, dot: dot)
        }
        tabBarModel.selected = currentIndex
        var status: [String] = []
        let summary = AgentRules.summary(tabs.flatMap { $0.tree.leaves }.map { store.status(of: $0) })
        if !summary.isEmpty { status.append(summary) }
        if let tab = currentTab, tab.zoomed != nil { status.append("zoom") }
        if let copyMode = focusedTerminal?.copyMode { status.append(copyMode.indicator) }
        if let keyIndicator { status.append(keyIndicator) }
        tabBarModel.status = status.joined(separator: "  ")
        store.refreshEntries()
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
    @objc func sidebarAction(_ sender: Any?) { toggleSidebar() }
    @objc func nextNeedsMeAction(_ sender: Any?) { jumpToNextNeedsMe() }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        for tab in tabs {
            for pane in tab.panes.values { pane.close() }
        }
        for id in tabs.flatMap({ $0.panes.keys }) { AgentStore.shared.remove(pane: id) }
        tabs.removeAll()
        AppState.shared.remove(self)
        AgentStore.shared.refreshEntries()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = currentTab?.focused, let pane = currentTab?.panes[id] {
            window?.makeFirstResponder(pane.focusView)
        }
        markFocusedSeen()
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
