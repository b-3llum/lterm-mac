# Working notes (README Design notes and Known gaps are built from this)

## Design notes
- AppKit app lifecycle (main.swift + AppDelegate), menus built in code. The pane area is AppKit because SwiftTerm views are NSViews. SwiftUI is used for side panels.
- UI-free logic lives in the `LtermCore` Swift package so it can be unit tested with `swift test`.
- SwiftTerm is pinned to v1.20.0 (stable release from August 2026).
- The `lterm` CLI is built as a separate target and copied into `lterm-mac.app/Contents/Resources/bin`. Panes get that folder on their PATH.
- Build output goes to ~/Library (DerivedData and SwiftPM scratch), not the repo, because iCloud Desktop sync adds file attributes that break code signing.

## Known gaps
