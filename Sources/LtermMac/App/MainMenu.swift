import AppKit

/// Builds the main menu in code (no storyboard or xib).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appMenu = submenu(in: main, title: "lterm")
        appMenu.addItem(withTitle: "About lterm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide lterm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit lterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let shell = submenu(in: main, title: "Shell")
        item(shell, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
        item(shell, "New Tab", #selector(TerminalWindowController.newTabAction(_:)), "t")
        shell.addItem(.separator())
        item(shell, "Split Right", #selector(TerminalWindowController.splitRightAction(_:)), "d")
        item(shell, "Split Down", #selector(TerminalWindowController.splitDownAction(_:)), "d", [.command, .shift])
        item(shell, "Zoom Pane", #selector(TerminalWindowController.zoomAction(_:)), "z", [.command, .shift])
        shell.addItem(.separator())
        item(shell, "Close Pane", #selector(TerminalWindowController.closePaneAction(_:)), "w")
        item(shell, "Close Tab", #selector(TerminalWindowController.closeTabAction(_:)), "w", [.command, .option])
        item(shell, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])

        let edit = submenu(in: main, title: "Edit")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = item(edit, "Find...", #selector(NSResponder.performTextFinderAction(_:)), "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let next = item(edit, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let previous = item(edit, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift])
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        item(edit, "Copy Mode", #selector(TerminalWindowController.copyModeAction(_:)), "")

        let view = submenu(in: main, title: "View")
        item(view, "Bigger", #selector(TerminalWindowController.biggerFontAction(_:)), "=")
        item(view, "Bigger ", #selector(TerminalWindowController.biggerFontAction(_:)), "+").isHidden = true
        item(view, "Smaller", #selector(TerminalWindowController.smallerFontAction(_:)), "-")
        item(view, "Actual Size", #selector(TerminalWindowController.resetFontAction(_:)), "0")

        let windowMenu = submenu(in: main, title: "Window")
        item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        windowMenu.addItem(.separator())
        item(windowMenu, "Next Tab", #selector(TerminalWindowController.nextTabAction(_:)), "]", [.command, .shift])
        item(windowMenu, "Previous Tab", #selector(TerminalWindowController.previousTabAction(_:)), "[", [.command, .shift])
        for number in 1...9 {
            let tabItem = item(windowMenu, "Tab \(number)", #selector(TerminalWindowController.selectTabAction(_:)), "\(number)")
            tabItem.tag = number
        }
        NSApp.windowsMenu = windowMenu

        let help = submenu(in: main, title: "Help")
        item(help, "lterm Shortcuts", #selector(TerminalWindowController.helpAction(_:)), "/", [.command, .shift])
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let holder = NSMenuItem()
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
