import Foundation
import Markdown

/// Turns a Markdown file into a full HTML page (GitHub-flavored: tables, task lists, strikethrough).
enum MarkdownRenderer {
    static func page(markdown: String, title: String, baseDirectory: URL) -> String {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        let body = HTMLFormatter.format(document)
        let base = baseDirectory.absoluteString.hasSuffix("/") ? baseDirectory.absoluteString : baseDirectory.absoluteString + "/"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <base href="\(escape(base))">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body><main>\(body)</main></body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: dark; }
    html { background: #0d1117; }
    body { margin: 0; color: #e6edf3; font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    main { max-width: 860px; margin: 0 auto; padding: 24px 28px 64px; }
    h1, h2 { border-bottom: 1px solid #30363d; padding-bottom: .3em; }
    h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 .6em; }
    a { color: #4493f8; text-decoration: none; }
    a:hover { text-decoration: underline; }
    img { max-width: 100%; }
    code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: #262c36; padding: .15em .35em; border-radius: 5px; }
    pre { background: #161b22; padding: 14px 16px; border-radius: 8px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin: 0; padding: 0 1em; color: #9198a1; border-left: 4px solid #3d444d; }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow: auto; }
    th, td { border: 1px solid #3d444d; padding: 6px 13px; }
    tr:nth-child(2n) { background: #151b23; }
    hr { border: 0; border-top: 1px solid #30363d; margin: 24px 0; }
    li + li { margin-top: .25em; }
    li > p { margin: 0; }
    li > input[type=checkbox] + p { display: inline; }
    li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.3em; }
    input[type=checkbox] { margin-right: .5em; }
    """
}
