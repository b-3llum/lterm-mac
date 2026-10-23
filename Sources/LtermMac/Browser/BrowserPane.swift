import AppKit
import WebKit

/// A web browser in a pane, for people and for scripts (`lterm browse ...`).
/// Each browser pane has its own private profile (no cookies or logins), thrown away when it closes.
/// Keys: Ctrl+L address bar, Ctrl+B / Ctrl+F back / forward, Ctrl+R reload, Ctrl+Q close.
@MainActor
final class BrowserPane: NSObject, Pane {
    let id: Int
    weak var owner: PaneOwner?
    private let container = NSView()
    private let toolbar = NSStackView()
    private let addressField = NSTextField()
    let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Page text from the last finished load, for `lterm pane read`.
    private var cachedText = ""
    private(set) var lastError: String?
    private var requested: URL?

    /// Why the last load did not show a page, if it did not.
    /// WebKit drops some loads without any error (for example ports it blocks, like 1 or 9).
    var loadProblem: String? {
        if let lastError { return lastError }
        let shown = webView.url?.absoluteString ?? "about:blank"
        if let requested, requested.absoluteString != "about:blank", shown == "about:blank", !webView.isLoading {
            return "nothing loaded (WebKit may block this address or port)"
        }
        return nil
    }

    var view: NSView { container }
    var focusView: NSView { webView }
    var kind: String { "browser" }
    var title: String {
        let text = webView.title ?? ""
        return text.isEmpty ? (webView.url?.host ?? "browser") : text
    }

    init(id: Int) {
        self.id = id
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        buildToolbar()
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.owner?.paneTitleChanged(self)
            }
        }
    }

    private func buildToolbar() {
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = tip
            return button
        }
        addressField.placeholderString = "Address (Ctrl+L)"
        addressField.font = .systemFont(ofSize: 12)
        addressField.bezelStyle = .roundedBezel
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for view in [button("chevron.left", "Back (Ctrl+B)", #selector(goBack)),
                     button("chevron.right", "Forward (Ctrl+F)", #selector(goForward)),
                     button("arrow.clockwise", "Reload (Ctrl+R)", #selector(reload)),
                     addressField] as [NSView] {
            toolbar.addArrangedSubview(view)
        }
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        for view in [toolbar, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Navigation

    /// Turns what a person types into a URL: `localhost:3000` becomes http, `example.com` becomes https.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") { return URL(string: trimmed) }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("0.0.0.0") || host.hasPrefix("[::1]")
        return URL(string: (local ? "http://" : "https://") + trimmed)
    }

    func load(_ text: String) throws {
        guard let url = Self.url(from: text) else { throw ControlError("not a URL: \(text)") }
        lastError = nil
        requested = url
        addressField.stringValue = url.absoluteString
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Waits until the current page finishes loading (or fails), at most `seconds`.
    func waitForLoad(seconds: Double = 20) async {
        // Give a click or a script a moment to start a navigation.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard webView.isLoading else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated { self?.finishWaiters() }
            }
        }
    }

    private func finishWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    @objc private func addressEntered() {
        try? load(addressField.stringValue)
        container.window?.makeFirstResponder(webView)
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }

    // MARK: Scripting

    /// Runs JavaScript (an async function body) and returns the JSON text of its result.
    func run(_ body: String, arguments: [String: Any] = [:]) async throws -> String {
        let wrapped = "const __r = await (async () => { \(body) })(); return JSON.stringify(__r === undefined ? null : __r);"
        do {
            let value = try await webView.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, contentWorld: .page)
            return value as? String ?? "null"
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw ControlError("JavaScript error: \(message)")
        }
    }

    /// Finds an element by CSS selector or by its visible text. Shared by click, type and wait.
    private static let findElement = """
    function __find(selector, text) {
      if (selector) return document.querySelector(selector);
      const want = text.trim().toLowerCase();
      const candidates = Array.from(document.querySelectorAll('a, button, input[type=submit], input[type=button], [role=button], label, summary, [onclick]'));
      const visible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const label = el => (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase();
      return candidates.find(el => visible(el) && label(el) === want)
        || candidates.find(el => visible(el) && label(el).includes(want))
        || Array.from(document.querySelectorAll('body *')).find(el => visible(el) && el.children.length === 0 && (el.innerText || '').trim().toLowerCase().includes(want));
    }
    function __describe(el) {
      const text = (el.innerText || el.value || '').trim().slice(0, 60);
      return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (text ? ' "' + text + '"' : '');
    }
    """

    func click(selector: String?, text: String?, x: Double?, y: Double?) async throws -> String {
        let result: String
        if let x, let y {
            result = try await run("""
            const el = document.elementFromPoint(x, y);
            if (!el) throw new Error('nothing at ' + x + ', ' + y);
            for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
              el.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, clientX: x, clientY: y, view: window}));
            }
            el.click();
            return el.tagName.toLowerCase();
            """, arguments: ["x": x, "y": y])
        } else {
            result = try await run(Self.findElement + """
            const el = __find(selector, text);
            if (!el) throw new Error('no element matches ' + (selector || JSON.stringify(text)));
            el.scrollIntoView({block: 'center'});
            el.focus();
            el.click();
            return __describe(el);
            """, arguments: ["selector": selector ?? "", "text": text ?? ""])
        }
        await waitForLoad(seconds: 15)
        return result
    }

    func type(selector: String?, text: String, enter: Bool) async throws -> String {
        let result = try await run(Self.findElement + """
        const el = selector ? __find(selector, '') : document.activeElement;
        if (!el || el === document.body) throw new Error(selector ? 'no element matches ' + selector : 'nothing is focused, pass --selector');
        el.focus();
        if (el.isContentEditable) {
          document.execCommand('insertText', false, text);
        } else {
          // Use the native setter so frameworks like React notice the change.
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, (el.value || '') + text);
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        if (enter) {
          for (const type of ['keydown', 'keypress', 'keyup']) {
            el.dispatchEvent(new KeyboardEvent(type, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true}));
          }
          if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        }
        return __describe(el);
        """, arguments: ["selector": selector ?? "", "text": text, "enter": enter])
        if enter { await waitForLoad(seconds: 15) }
        return result
    }

    /// Waits until the text appears on the page or the selector matches. Returns false on timeout.
    func wait(text: String?, selector: String?, timeout: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !webView.isLoading {
                let found = try await run(Self.findElement + """
                if (selector) return !!document.querySelector(selector);
                return (document.body ? document.body.innerText : '').toLowerCase().includes(text.toLowerCase());
                """, arguments: ["selector": selector ?? "", "text": text ?? ""])
                if found == "true" { return true }
            }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Page text: body (default), title, html, links, or the text of every element matching a CSS selector.
    func text(_ what: String) async throws -> String {
        let json: String
        switch what {
        case "body", "":
            json = try await run("return document.body ? document.body.innerText : '';")
        case "title":
            json = try await run("return document.title;")
        case "html":
            json = try await run("return document.documentElement.outerHTML;")
        case "links":
            json = try await run("""
            return Array.from(document.querySelectorAll('a[href]'))
              .map(a => ((a.innerText || a.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' ') || '(no text)') + '  ' + a.href)
              .join('\\n');
            """)
        default:
            json = try await run("""
            const found = Array.from(document.querySelectorAll(selector));
            if (!found.length) throw new Error('no element matches ' + selector);
            return found.map(el => el.innerText).join('\\n');
            """, arguments: ["selector": what])
        }
        return Self.decodeString(json)
    }

    /// Runs any JavaScript expression or statements and returns the result as text.
    func evaluate(_ code: String) async throws -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try it as an expression first so `lterm browse eval document.title` prints the title.
        // If that is not valid syntax, run it as statements (use `return` to get a value back).
        let json: String
        do {
            json = try await run("return (\(trimmed)\n);")
        } catch let error as ControlError where error.message.contains("SyntaxError") {
            json = try await run(trimmed)
        }
        return json.hasPrefix("\"") ? Self.decodeString(json) : json
    }

    func screenshot(to path: String) async throws -> String {
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: nil)
        } catch {
            throw ControlError("screenshot failed: \(error.localizedDescription)")
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ControlError("could not encode the screenshot")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        return "\(path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh))"
    }

    private static func decodeString(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return json == "null" ? "" : json }
        return value
    }

    // MARK: Keys

    /// Ctrl+L / B / F / R / Q. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "l":
            container.window?.makeFirstResponder(addressField)
            addressField.currentEditor()?.selectAll(nil)
        case "b": webView.goBack()
        case "f": webView.goForward()
        case "r": webView.reload()
        case "q": owner?.paneExited(self)
        default: return false
        }
        return true
    }

    // MARK: Pane

    func close() {
        titleObservation = nil
        webView.stopLoading()
        finishWaiters()
    }

    func readText(lines: Int) -> String {
        cachedText.components(separatedBy: "\n").suffix(max(lines, 1)).joined(separator: "\n")
    }

    private func refreshCachedText() {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
            MainActor.assumeIsolated { self?.cachedText = value as? String ?? "" }
        }
    }
}

extension BrowserPane: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, container.window?.firstResponder !== addressField.currentEditor() {
            addressField.stringValue = url.absoluteString
        }
        refreshCachedText()
        owner?.paneTitleChanged(self)
        finishWaiters()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        let nsError = error as NSError
        // A new navigation replacing the old one is not a real failure.
        guard nsError.code != NSURLErrorCancelled else { return }
        lastError = nsError.localizedDescription
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        webView.loadHTMLString("""
        <html><body style="font: 14px -apple-system; color: #ddd; background: #1a1a1a; padding: 2em">
        <h3>Could not load the page</h3><p>\(MarkdownRenderer.escape(failedURL))</p><p>\(MarkdownRenderer.escape(nsError.localizedDescription))</p>
        </body></html>
        """, baseURL: nil)
        finishWaiters()
    }

    /// Links that want a new window open in this pane instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Pages cannot open alert boxes (they would block scripts driving the pane). Log them instead.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        NSLog("lterm browser pane %d alert: %@", id, message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        completionHandler(true)
    }
}
