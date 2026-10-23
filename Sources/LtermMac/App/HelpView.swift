import SwiftUI
import LtermCore

/// The shortcut list shown with Ctrl+Space ? or Help > lterm Shortcuts.
struct HelpView: View {
    let leader: String
    let dismiss: () -> Void

    private let macKeys: [(String, String)] = [
        ("Cmd+T", "new tab"),
        ("Cmd+D / Cmd+Shift+D", "split right / down"),
        ("Cmd+W", "close pane"),
        ("Cmd+Shift+] / [", "next / previous tab"),
        ("Cmd+1 to 9", "go to tab"),
        ("Cmd+= / - / 0", "font bigger / smaller / reset"),
        ("Cmd+C / Cmd+V", "copy / paste"),
        ("Cmd+F", "search scrollback"),
        ("Ctrl+Shift+A", "agents sidebar"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lterm shortcuts").font(.title2.bold())
            Text("Press \(leader), let go, then press a key.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 32) {
                table(LeaderKeymap.helpLines)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Without the leader").font(.headline)
                    table(macKeys)
                    Text("Copy mode").font(.headline).padding(.top, 6)
                    Text("h j k l, w b, 0 $, g G to move\nv / V select, y copy, / search\nn / N next / previous match, q quit")
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                // Hidden button so Escape closes the sheet as well as Return.
                Button("", action: dismiss).keyboardShortcut(.cancelAction).hidden()
                Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640)
        .fixedSize()
    }

    private func table(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(row.1).font(.system(size: 12))
                }
            }
        }
    }
}
