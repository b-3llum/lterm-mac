# Working notes (README Design notes and Known gaps are built from this)

## Design notes
- AppKit app lifecycle (main.swift + AppDelegate), menus built in code. The pane area is AppKit because SwiftTerm views are NSViews. SwiftUI is used for side panels.
- UI-free logic lives in the `LtermCore` Swift package so it can be unit tested with `swift test`.
- SwiftTerm is pinned to v1.20.0 (stable release from August 2026).
- The `lterm` CLI is built as a separate target and copied into `lterm-mac.app/Contents/Resources/bin`. Panes get that folder on their PATH.
- Build output goes to ~/Library (DerivedData and SwiftPM scratch), not the repo, because iCloud Desktop sync adds file attributes that break code signing.
- Panes are a binary tree (`LayoutTree` in LtermCore). Moving between panes picks the neighbor by on-screen position, ties go to the top-left-most pane.
- Resize (H J K L) moves the nearest divider that crosses that direction by 5%, like tmux. After one resize the same keys keep working for 1.5 s without the leader.
- Pressing the leader twice sends the leader key itself to the program (Ctrl+Space is NUL).
- New splits and tabs start in the focused shell's current folder (read from the process table, no shell setup needed).
- Cmd+W closes the pane. The last pane closes the tab, the last tab closes the window. Cmd+Option+W closes the whole tab.
- Our own tab bar is used instead of native macOS window tabs, so tabs can show agent dots and work with the leader keys.
- Scrollback search uses SwiftTerm's built-in find bar (Cmd+F, Cmd+G, Cmd+Shift+G, or Ctrl+Space /).
- Settings live in UserDefaults: `defaults write com.b3llum.lterm-mac fontSize 14`, `fontName`, `leader` (for example `ctrl+a`). `LTERM_LEADER` overrides the leader.
- Copy mode logic (motions, v/V selection, search, smart case) is plain Swift in LtermCore with tests. In the app it drives SwiftTerm's own selection, so the highlight looks the same as a mouse selection. The cursor is shown as a one-cell selection. Also supports ctrl-u / ctrl-d, and Return copies like y.
- macOS uses Ctrl+Space for "Select previous input source" by default. If you have more than one keyboard input source, turn that shortcut off in System Settings > Keyboard > Keyboard Shortcuts > Input Sources, or pick another leader.
- Copy mode counts columns in characters, so lines with wide characters (CJK, some emoji) can be off by a cell.
