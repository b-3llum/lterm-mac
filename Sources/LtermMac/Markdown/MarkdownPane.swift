import AppKit
import WebKit
import Darwin

/// A pane that shows a Markdown file with its images. Reloads when the file changes.
/// Keys: j / k scroll, d / u half a page, g / G top / bottom, q close.
@MainActor
final class MarkdownPane: NSObject, Pane {
    let id: Int
    let fileURL: URL
    weak var owner: PaneOwner?
    private let webView: WKWebView
    private var watcher: DispatchSourceFileSystemObject?
    private var source = ""
    private let pageFile: URL

    var view: NSView { webView }
    var focusView: NSView { webView }
    var title: String { fileURL.lastPathComponent }
    var kind: String { "markdown" }

    init(id: Int, fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        // The page is plain rendered Markdown. Scripts inside it do not run.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lterm-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pageFile = folder.appendingPathComponent("pane-\(id).html")
        super.init()
        webView.navigationDelegate = self
        render(keepScroll: false)
        watch()
    }

    /// Reads the file and shows it. With `keepScroll` the scroll position survives the reload.
    private func render(keepScroll: Bool) {
        let markdown: String
        do {
            markdown = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            markdown = "# Could not read \(fileURL.lastPathComponent)\n\n`\(error.localizedDescription)`"
        }
        source = markdown
        let html = MarkdownRenderer.page(markdown: markdown, title: title, baseDirectory: fileURL.deletingLastPathComponent())
        do {
            try html.write(to: pageFile, atomically: true, encoding: .utf8)
        } catch {
            webView.loadHTMLString(html, baseURL: fileURL.deletingLastPathComponent())
            return
        }
        let load = { [weak self] in
            guard let self else { return }
            // Read access to the whole disk so relative and absolute image paths both work.
            self.webView.loadFileURL(self.pageFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        if keepScroll {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    self?.pendingScroll = value as? Double
                    load()
                }
            }
        } else {
            load()
        }
    }

    private var pendingScroll: Double?

    /// Watches the file. Editors often replace the file, so the watch is set up again after a rename.
    private func watch() {
        watcher?.cancel()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let replaced = !(self.watcher?.data.intersection([.rename, .delete]).isEmpty ?? true)
                // Give the editor a moment to finish writing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    MainActor.assumeIsolated {
                        self.render(keepScroll: true)
                        if replaced { self.watch() }
                    }
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// Vim-style scrolling. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.characters else { return false }
        let script: String
        switch key {
        case "j": script = "window.scrollBy(0, 60)"
        case "k": script = "window.scrollBy(0, -60)"
        case "d", " ": script = "window.scrollBy(0, window.innerHeight / 2)"
        case "u": script = "window.scrollBy(0, -window.innerHeight / 2)"
        case "g": script = "window.scrollTo(0, 0)"
        case "G": script = "window.scrollTo(0, document.body.scrollHeight)"
        case "q":
            owner?.paneExited(self)
            return true
        default:
            return false
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
        return true
    }

    func close() {
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.removeItem(at: pageFile)
    }

    func readText(lines: Int) -> String {
        source.components(separatedBy: "\n").suffix(max(lines, 1)).joined(separator: "\n")
    }
}

extension MarkdownPane: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let y = pendingScroll {
            pendingScroll = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
        }
    }

    /// Links open in the default browser. Jumps inside the page stay here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "file", url.path == pageFile.path, url.fragment != nil {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == "md", let owner = owner as? TerminalWindowController {
            // Another Markdown file: open it in a new tab, like following a link in a browser.
            owner.openMarkdown(url, split: false)
        } else {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
