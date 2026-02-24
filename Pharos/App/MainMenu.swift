import AppKit

enum MainMenu {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pharos", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pharos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pharos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu (connections & queries)
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Connection...", action: #selector(MainWindowController.showAddConnectionSheet), keyEquivalent: "n")
        fileMenu.addItem(.separator())

        let newTab = fileMenu.addItem(withTitle: "New Tab", action: #selector(ContentViewController.menuNewTab(_:)), keyEquivalent: "t")
        newTab.keyEquivalentModifierMask = [.command]

        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(ContentViewController.menuCloseTab(_:)), keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command]

        let reopenTab = fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(ContentViewController.menuReopenTab(_:)), keyEquivalent: "T")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(.separator())

        let saveQuery = fileMenu.addItem(withTitle: "Save Query…", action: #selector(ContentViewController.menuSaveQuery(_:)), keyEquivalent: "s")
        saveQuery.keyEquivalentModifierMask = [.command]

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(ContentViewController.showFind), keyEquivalent: "f")

        let filterItem = editMenu.addItem(withTitle: "Filter Results…", action: #selector(ContentViewController.showFilter), keyEquivalent: "f")
        filterItem.keyEquivalentModifierMask = [.command, .shift]

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Query menu
        let queryMenuItem = NSMenuItem()
        let queryMenu = NSMenu(title: "Query")

        let runItem = queryMenu.addItem(withTitle: "Run Query", action: #selector(ContentViewController.menuRunQuery(_:)), keyEquivalent: "\r")
        runItem.keyEquivalentModifierMask = [.command]

        let cancelItem = queryMenu.addItem(withTitle: "Cancel Query", action: #selector(ContentViewController.menuCancelQuery(_:)), keyEquivalent: ".")
        cancelItem.keyEquivalentModifierMask = [.command]

        queryMenu.addItem(.separator())

        let formatItem = queryMenu.addItem(withTitle: "Format SQL", action: #selector(ContentViewController.menuFormatSQL(_:)), keyEquivalent: "i")
        formatItem.keyEquivalentModifierMask = [.control]

        queryMenuItem.submenu = queryMenu
        mainMenu.addItem(queryMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .control]

        viewMenu.addItem(.separator())

        // Tab switching shortcuts Cmd+1-9
        for i in 1...9 {
            let item = viewMenu.addItem(
                withTitle: "Tab \(i)",
                action: #selector(ContentViewController.menuSelectTab(_:)),
                keyEquivalent: "\(i)"
            )
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1 // Zero-based index
        }

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }
}

// MARK: - AppDelegate actions

extension AppDelegate {
    @objc func openSettings(_ sender: Any?) {
        // TODO: Open settings window
    }
}
