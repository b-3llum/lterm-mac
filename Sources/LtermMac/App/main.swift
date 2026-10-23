import AppKit

// Plain AppKit entry point. The pane area is AppKit (SwiftTerm views are NSViews);
// SwiftUI is used for side panels hosted in NSHostingView.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
