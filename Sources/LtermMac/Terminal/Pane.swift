import AppKit

/// Something that can live in a pane: a terminal, a Markdown viewer or a browser.
@MainActor
protocol Pane: AnyObject {
    var id: Int { get }
    /// The view placed in the layout.
    var view: NSView { get }
    /// The view that should get keyboard focus.
    var focusView: NSView { get }
    var title: String { get }
    var owner: PaneOwner? { get set }
    /// Stops processes and frees resources. Called once when the pane goes away.
    func close()
    /// The last `lines` lines of visible text, for `lterm pane read`.
    func readText(lines: Int) -> String
    /// Short kind name shown by `lterm pane list`.
    var kind: String { get }
}

/// Gets told about pane events. Implemented by the window controller.
@MainActor
protocol PaneOwner: AnyObject {
    func paneTitleChanged(_ pane: Pane)
    func paneExited(_ pane: Pane)
}
