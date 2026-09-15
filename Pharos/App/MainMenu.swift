import AppKit

enum MainMenu {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Pharos"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let settingsItem = appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        // Empty submenu — AppKit populates it with the system-provided Services.
        let servicesItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: String(localized: "Services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Pharos"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Pharos"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu (connections & queries)
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))

        let manageConnections = fileMenu.addItem(withTitle: String(localized: "Manage Connections…"), action: #selector(MainWindowController.showConnectionsManager), keyEquivalent: "N")
        manageConnections.keyEquivalentModifierMask = [.command, .shift]
        manageConnections.image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)

        let connectItem = fileMenu.addItem(withTitle: String(localized: "Connect"), action: #selector(ContentViewController.menuConnect(_:)), keyEquivalent: "")
        connectItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)

        let disconnectItem = fileMenu.addItem(withTitle: String(localized: "Disconnect"), action: #selector(ContentViewController.menuDisconnect(_:)), keyEquivalent: "")
        disconnectItem.image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil)

        let refreshMetadata = fileMenu.addItem(withTitle: String(localized: "Refresh Metadata"), action: #selector(ContentViewController.menuRefreshMetadata(_:)), keyEquivalent: "r")
        refreshMetadata.keyEquivalentModifierMask = [.command, .shift]
        refreshMetadata.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)

        let openItem = fileMenu.addItem(withTitle: String(localized: "Open…"), action: #selector(AppDelegate.menuOpenSQLFile(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]

        fileMenu.addItem(.separator())

        let newTab = fileMenu.addItem(withTitle: String(localized: "New Tab"), action: #selector(ContentViewController.menuNewTab(_:)), keyEquivalent: "t")
        newTab.keyEquivalentModifierMask = [.command]
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)

        let closeTab = fileMenu.addItem(withTitle: String(localized: "Close Tab"), action: #selector(ContentViewController.menuCloseTab(_:)), keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command]
        closeTab.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)

        let reopenTab = fileMenu.addItem(withTitle: String(localized: "Reopen Closed Tab"), action: #selector(ContentViewController.menuReopenTab(_:)), keyEquivalent: "T")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(.separator())

        let saveQuery = fileMenu.addItem(withTitle: String(localized: "Save Query…"), action: #selector(ContentViewController.menuSaveQuery(_:)), keyEquivalent: "s")
        saveQuery.keyEquivalentModifierMask = [.command]
        saveQuery.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)

        let exportEditor = fileMenu.addItem(withTitle: String(localized: "Export Query as SQL File…"), action: #selector(ContentViewController.menuExportEditorAsSQL(_:)), keyEquivalent: "s")
        exportEditor.keyEquivalentModifierMask = [.command, .option]

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        // Find submenu — routed through the responder chain (nil target) so
        // whichever view is first responder (editor or results grid) handles
        // it. See SQLTextView (NSTextView's own performTextFinderAction),
        // ResultsTableView, and ContentViewController's fallback.
        let findMenuItem = NSMenuItem(title: String(localized: "Find"), action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: String(localized: "Find"))

        let findShow = findMenu.addItem(withTitle: String(localized: "Find…"), action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "f")
        findShow.keyEquivalentModifierMask = [.command]
        findShow.tag = NSTextFinder.Action.showFindInterface.rawValue

        let findNext = findMenu.addItem(withTitle: String(localized: "Find Next"), action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "g")
        findNext.keyEquivalentModifierMask = [.command]
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue

        let findPrevious = findMenu.addItem(withTitle: String(localized: "Find Previous"), action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = NSTextFinder.Action.previousMatch.rawValue

        let useSelectionForFind = findMenu.addItem(withTitle: String(localized: "Use Selection for Find"), action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "e")
        useSelectionForFind.keyEquivalentModifierMask = [.command]
        useSelectionForFind.tag = NSTextFinder.Action.setSearchString.rawValue

        let jumpToSelection = findMenu.addItem(withTitle: String(localized: "Jump to Selection"), action: #selector(NSTextView.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        jumpToSelection.keyEquivalentModifierMask = [.command]

        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        let filterItem = editMenu.addItem(withTitle: String(localized: "Filter Results…"), action: #selector(ContentViewController.showFilter), keyEquivalent: "f")
        filterItem.keyEquivalentModifierMask = [.command, .shift]

        let tagRowItem = editMenu.addItem(withTitle: String(localized: "Add Tag…"), action: #selector(ContentViewController.menuTagRow(_:)), keyEquivalent: "l")
        tagRowItem.keyEquivalentModifierMask = [.command]

        editMenu.addItem(withTitle: String(localized: "Manage Tags…"),
                         action: #selector(ContentViewController.menuManageTags(_:)),
                         keyEquivalent: "")

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Query menu
        let queryMenuItem = NSMenuItem()
        let queryMenu = NSMenu(title: String(localized: "Query"))

        let runItem = queryMenu.addItem(withTitle: String(localized: "Run Query"), action: #selector(ContentViewController.menuRunQuery(_:)), keyEquivalent: "\r")
        runItem.keyEquivalentModifierMask = [.command]
        runItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)

        let runAllItem = queryMenu.addItem(withTitle: String(localized: "Run All Queries"), action: #selector(ContentViewController.menuRunAllQueries(_:)), keyEquivalent: "\r")
        runAllItem.keyEquivalentModifierMask = [.command, .option]
        runAllItem.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)

        let cancelItem = queryMenu.addItem(withTitle: String(localized: "Cancel Query"), action: #selector(ContentViewController.menuCancelQuery(_:)), keyEquivalent: ".")
        cancelItem.keyEquivalentModifierMask = [.command]
        cancelItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)

        queryMenu.addItem(.separator())

        let formatItem = queryMenu.addItem(withTitle: String(localized: "Format SQL"), action: #selector(ContentViewController.menuFormatSQL(_:)), keyEquivalent: "i")
        formatItem.keyEquivalentModifierMask = [.control]
        formatItem.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)

        queryMenuItem.submenu = queryMenu
        mainMenu.addItem(queryMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View"))
        // Standard split view actions. `PharosSplitViewController.validateMenuItem`
        // switches the titles between Show and Hide.
        let sidebarToggle = viewMenu.addItem(
            withTitle: String(localized: "Hide Sidebar"),
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarToggle.keyEquivalentModifierMask = [.command, .control]
        sidebarToggle.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)

        let inspectorToggle = viewMenu.addItem(
            withTitle: String(localized: "Show Inspector"),
            action: #selector(NSSplitViewController.toggleInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorToggle.keyEquivalentModifierMask = [.command, .option]
        inspectorToggle.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: nil)

        viewMenu.addItem(.separator())
        let customizeToolbar = viewMenu.addItem(withTitle: String(localized: "Customize Toolbar…"), action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        customizeToolbar.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)

        viewMenu.addItem(.separator())

        // Tab switching shortcuts Cmd+1-9
        for i in 1...9 {
            let item = viewMenu.addItem(
                withTitle: String(localized: "Tab \(i)"),
                action: #selector(ContentViewController.menuSelectTab(_:)),
                keyEquivalent: "\(i)"
            )
            item.keyEquivalentModifierMask = [.command]
            item.tag = i - 1 // Zero-based index
        }

        viewMenu.addItem(.separator())

        let nextTabItem = viewMenu.addItem(
            withTitle: String(localized: "Show Next Tab"),
            action: #selector(ContentViewController.menuSelectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]

        let previousTabItem = viewMenu.addItem(
            withTitle: String(localized: "Show Previous Tab"),
            action: #selector(ContentViewController.menuSelectPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]

        let nextResultTabItem = viewMenu.addItem(
            withTitle: String(localized: "Show Next Result Tab"),
            action: #selector(ContentViewController.menuSelectNextResultTab(_:)),
            keyEquivalent: "\t"
        )
        nextResultTabItem.keyEquivalentModifierMask = [.control]

        let previousResultTabItem = viewMenu.addItem(
            withTitle: String(localized: "Show Previous Result Tab"),
            action: #selector(ContentViewController.menuSelectPreviousResultTab(_:)),
            keyEquivalent: "\t"
        )
        previousResultTabItem.keyEquivalentModifierMask = [.control, .shift]

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help"))

        let pharosHelp = helpMenu.addItem(withTitle: String(localized: "Pharos Help"), action: #selector(AppDelegate.openPharosHelp(_:)), keyEquivalent: "?")
        pharosHelp.keyEquivalentModifierMask = [.command]
        pharosHelp.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)

        helpMenu.addItem(withTitle: String(localized: "Keyboard Shortcuts"), action: #selector(AppDelegate.openKeyboardShortcuts(_:)), keyEquivalent: "")
        helpMenu.addItem(withTitle: String(localized: "Release Notes"), action: #selector(AppDelegate.openReleaseNotes(_:)), keyEquivalent: "")

        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }
}

// MARK: - AppDelegate actions

extension AppDelegate {
    /// Settings is a window of its own, so it opens whether or not the main
    /// window is on screen — the old sheet needed a window to attach to and
    /// did nothing without one.
    @MainActor
    @objc func openSettings(_: Any?) {
        SettingsWindowController.shared.show()
    }
}
