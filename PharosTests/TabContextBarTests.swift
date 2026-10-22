// Standalone test for TabContextBar, the tab's context row: connection ›
// schema, the connection's state, the transaction chip. Compiled by
// scripts/test-tab-context-bar.sh. Clicks go through hitTest from the window's
// content view, the way AppKit routes a real click.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// Counts AppKit's conflict reports (`visualizeConstraints` is called for each
/// one while NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints is on).
private final class SpyWindow: NSWindow {
    static var conflicts = 0
    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        if !(constraints ?? []).isEmpty { Self.conflicts += 1 }
    }
}

@MainActor
private final class Fixture {
    let window: SpyWindow
    let bar = TabContextBar()

    init(width: CGFloat = 900) {
        window = SpyWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.titled],
                           backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        window.contentView = root
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bar.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
        ])
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    func layout() { window.contentView?.layoutSubtreeIfNeeded() }

    func hit(_ view: NSView) -> NSView? {
        layout()
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: window.contentView)
        return window.contentView?.hitTest(centre)
    }

    func click(_ button: NSButton) -> Bool {
        guard let target = hit(button) as? NSButton else { return false }
        target.performClick(nil)
        return target === button
    }
}

private let coda = TabContextBar.ConnectionItem(id: "c1", name: "Coda", state: .connected)
private let billing = TabContextBar.ConnectionItem(id: "c2", name: "Billing", state: .disconnected)

/// One group of the pop-up, as the owner builds it.
private func group(_ title: String, _ items: [TabContextBar.ConnectionItem]) -> TabContextBar.ConnectionSection {
    TabContextBar.ConnectionSection(title: title, symbolName: "server.rack", items: items)
}

/// C1: a DuckDB item says where its file is, and "File not found" when the
/// menu opens on a file that is gone.
@MainActor
private func testFileLocations() {
    let f = Fixture()
    let popUp = f.bar.connectionPopUp
    let sales = TabContextBar.ConnectionItem(id: "d1", name: "sales", state: .disconnected,
                                             place: "~/Data/sales.duckdb", filePath: "/Users/x/Data/sales.duckdb",
                                             kind: .file)
    let open = TabContextBar.ConnectionItem(id: "d2", name: "open", state: .connected,
                                            place: "~/open.duckdb", filePath: "/Users/x/open.duckdb", kind: .file,
                                            badge: "Read-only", toolTip: "open\n/Users/x/open.duckdb")
    let mem = TabContextBar.ConnectionItem(id: "d3", name: "scratch", state: .connected, place: "In memory",
                                           kind: .memory)
    f.bar.fileExists = { _ in false }
    f.bar.showConnections([group("Open Files", [mem]), group("PostgreSQL", [coda]), group("DuckDB", [sales, open])],
                          selectedId: "d1")
    let item = popUp.itemArray.first { $0.title == "sales" }
    expect(item?.subtitle == "Not connected · ~/Data/sales.duckdb", "the subtitle is the state, then the location",
           item?.subtitle ?? "nil")
    expect(item?.toolTip == "/Users/x/Data/sales.duckdb", "the tooltip is the full path")
    expect(popUp.itemArray.first { $0.title == "scratch" }?.subtitle == "Connected · In memory", "in-memory says so")
    expect(popUp.itemArray.first { $0.title == "Coda" }?.subtitle == "Connected", "a server keeps the state alone")
    let headers = popUp.itemArray.filter { $0.tag == TabContextBar.headerTag }
        .compactMap { ($0.view as? ConnectionMenuHeaderView)?.title }
    expect(headers == ["Open Files", "PostgreSQL", "DuckDB"], "a header for each group, in the owner's order", "\(headers)")
    // The approved design: header views with counts, a separator between
    // groups, 28 pt tiles, badges, and the tooltip with the full details.
    let headerViews = popUp.itemArray.compactMap { $0.view as? ConnectionMenuHeaderView }
    expect(headerViews.map(\.count) == [1, 1, 2], "each header counts its group", "\(headerViews.map(\.count))")
    expect(headerViews.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty },
           "a header reads its title and count to VoiceOver")
    let items = popUp.itemArray
    let firstHeaders = items.indices.filter { items[$0].tag == TabContextBar.headerTag }
    expect(firstHeaders.dropFirst().allSatisfy { items[$0 - 1].isSeparatorItem }, "a separator before every later header")
    expect(popUp.itemArray.first { $0.title == "Coda" }?.image?.size == NSSize(width: 28, height: 28), "rows have a 28 pt tile")
    let openItem = popUp.itemArray.first { $0.title == "open" }
    expect(openItem?.badge?.stringValue == "Read-only", "the badge shows", openItem?.badge?.stringValue ?? "nil")
    expect(openItem?.toolTip == "open\n/Users/x/open.duckdb", "the tooltip is the owner's full details")
    expect(popUp.itemArray.first { $0.title == "sales" }?.badge == nil, "no badge when there is nothing to say")
    let shown = (popUp.cell as? NSPopUpButtonCell)?.menuItem
    expect((popUp.cell as? NSPopUpButtonCell)?.usesItemFromMenu == false && shown?.title == "sales"
           && shown?.image?.size == NSSize(width: 16, height: 16),
           "the closed button shows the name and a 16 pt tile", "\(shown?.title ?? "nil") \(String(describing: shown?.image?.size))")

    f.bar.markMissingFiles()
    expect(item?.subtitle == "File not found · ~/Data/sales.duckdb", "a gone file says so when the menu opens",
           item?.subtitle ?? "nil")
    expect(popUp.itemArray.first { $0.title == "open" }?.subtitle == "Connected · ~/open.duckdb",
           "an open file is never marked missing")
    f.bar.showConnections([group("DuckDB", [sales])], selectedId: "d1")
    expect(popUp.itemArray.filter { $0.tag == TabContextBar.headerTag }.map(\.title) == ["DuckDB"],
           "one group still has its header")
    expect(!popUp.itemArray.prefix(2).contains(where: \.isSeparatorItem), "no separator before the first header")

    // C2: the Read-only badge reads as plain words, with the help.
    expect(f.bar.readOnlyBadge.isHidden, "no badge by default")
    f.bar.showReadOnly(help: "Set to Read-only.")
    let label = f.bar.readOnlyBadge.arrangedSubviews.compactMap { $0 as? NSTextField }.first
    expect(!f.bar.readOnlyBadge.isHidden && label?.stringValue == "Read-only", "the badge shows the words")
    expect(label?.accessibilityHelp() == "Set to Read-only.", "the help reaches VoiceOver")
    expect(!(label?.stringValue.contains("\u{FFFC}") ?? true), "no attachment character in what VoiceOver reads")
    f.bar.showReadOnly(help: nil)
    expect(f.bar.readOnlyBadge.isHidden, "nil hides it")
}

@MainActor
private func testConnections() {
    let f = Fixture()
    let popUp = f.bar.connectionPopUp
    f.bar.showConnections([group("PostgreSQL", [coda, billing])], selectedId: "c1")
    expect(popUp.titleOfSelectedItem == "Coda", "the button shows the tab's connection")
    expect(popUp.itemArray.contains { $0.title == "Manage Connections…" }, "Manage Connections… is the last item")
    expect(popUp.itemArray.first { $0.title == "Billing" }?.subtitle == "Not connected",
           "each connection says its state in words, not only in colour")
    expect(!popUp.itemArray.contains { $0.title == "Connect" || $0.title == "Disconnect" },
           "no actions in the pop-up: Connect is its own button (HIG, Pop-up buttons)")

    var chosen: [String] = []
    var managed = 0
    f.bar.onChooseConnection = { chosen.append($0) }
    f.bar.onManageConnections = { managed += 1 }
    popUp.selectItem(withTitle: "Billing")
    popUp.sendAction(popUp.action, to: popUp.target)
    expect(chosen == ["c2"], "choosing another connection asks the owner to move the tab", "\(chosen)")
    expect(popUp.titleOfSelectedItem == "Coda", "the button keeps the tab's connection until the owner moves it")
    popUp.selectItem(withTitle: "Coda")
    popUp.sendAction(popUp.action, to: popUp.target)
    expect(chosen == ["c2"], "choosing the current connection does nothing")
    popUp.selectItem(withTitle: "Manage Connections…")
    popUp.sendAction(popUp.action, to: popUp.target)
    expect(managed == 1 && popUp.titleOfSelectedItem == "Coda", "Manage Connections… opens the manager and the button snaps back")

    // The menu opens below the button (ConnectionPopUpButton), so each item
    // routes itself; the result is the same as through the button's action.
    expect(popUp.itemArray.first { $0.title == "Coda" }?.state == .on, "the tab's connection has the checkmark")
    expect(popUp.itemArray.first { $0.title == "Billing" }?.state == .off, "another connection has none")
    let billingItem = popUp.itemArray.first { $0.title == "Billing" }!
    _ = (billingItem.target as AnyObject).perform(billingItem.action, with: billingItem)
    expect(chosen == ["c2", "c2"], "an item's own action asks the owner once", "\(chosen)")
    expect(popUp.titleOfSelectedItem == "Coda", "and the button snaps back")
    let manageItem = popUp.itemArray.first { $0.title == "Manage Connections…" }!
    _ = (manageItem.target as AnyObject).perform(manageItem.action, with: manageItem)
    expect(managed == 2, "Manage Connections… routes itself too")
    let b = NSRect(x: 0, y: 0, width: 180, height: 24)
    expect(ConnectionPopUpButton.menuOrigin(in: b, flipped: true) == NSPoint(x: 0, y: 26), "the menu's top edge sits 2 pt below the button (flipped)")
    expect(ConnectionPopUpButton.menuOrigin(in: b, flipped: false) == NSPoint(x: 0, y: -2), "and below it when not flipped")
    expect(popUp.isFlipped, "NSPopUpButton is flipped, so the flipped origin is the one used")

    f.bar.showConnections([group("PostgreSQL", [coda, billing])], selectedId: nil)
    expect(popUp.titleOfSelectedItem == "Choose Connection", "no connection: the button says Choose Connection")
    expect(!popUp.itemArray.contains { $0.state == .on }, "no checkmark without a connection")
    expect(popUp.accessibilityIdentifier() == "editor.context.connection", "AX id")
}

@MainActor
private func testStates() {
    let f = Fixture()
    var connects = 0
    f.bar.onConnect = { connects += 1 }

    f.bar.showState(.notConnected)
    f.layout()
    expect(!f.bar.stateButton.isHidden && f.bar.stateButton.title == "Connect", "not connected: Connect button")
    expect(f.click(f.bar.stateButton) && connects == 1, "Connect reaches its button through hit-testing")

    f.bar.showState(.connecting)
    expect(f.bar.stateButton.isHidden && f.bar.stateLabel.stringValue == "Connecting…", "connecting: words, no button")

    f.bar.showState(.failed(reason: "password authentication failed"))
    expect(f.bar.stateButton.title == "Try Again" && f.bar.stateButton.toolTip == "password authentication failed",
           "error: Try Again, with the reason")
    expect(f.click(f.bar.stateButton) && connects == 2, "Try Again connects")

    f.bar.showState(.connected)
    expect(f.bar.stateButton.isHidden && f.bar.stateLabel.stringValue == "Connected" && !f.bar.schemaButton.isHidden,
           "connected: words and the schema pop-up")
    f.bar.showState(.chooseConnection)
    expect(f.bar.schemaButton.isHidden, "no connection: no schema pop-up")
    expect(f.bar.stateButton.accessibilityIdentifier() == "editor.context.connect", "AX id")
}

@MainActor
private func testSchema() {
    let f = Fixture()
    f.bar.showState(.connected)
    var asked = 0
    f.bar.onSchema = { _ in asked += 1 }
    f.bar.showSchema(title: "public", isEnabled: true)
    f.layout()
    expect(f.bar.schemaButton.titleOfSelectedItem == "public" && f.bar.schemaButton.accessibilityValue() as? String == "public",
           "the schema pop-up shows the tab's schema")
    let target = f.hit(f.bar.schemaButton)
    expect(target === f.bar.schemaButton, "a click reaches the schema pop-up", "\(String(describing: target))")
    f.bar.schemaButton.onActivate?(f.bar.schemaButton)
    expect(asked == 1, "it asks the owner for the schema list")
    f.bar.showSchema(title: "No Schema", isEnabled: false)
    expect(!f.bar.schemaButton.isEnabled, "disabled while there is nothing to choose")
}

@MainActor
private func testChip() {
    let f = Fixture()
    var menus = 0
    f.bar.transactionMenu = { menus += 1; return nil }
    f.bar.showTransaction(nil)
    expect(f.bar.transactionChip.isHidden, "no transaction: no chip")
    f.bar.showTransaction(.transaction(elapsed: 134, idleRemaining: 466))
    f.layout()
    expect(!f.bar.transactionChip.isHidden && f.bar.transactionChip.title == "Transaction open · 2 min", "open: age on the chip")
    expect(f.bar.transactionChip.toolTip?.contains("rolls it back after") == true, "the full message is the tooltip")
    expect(f.click(f.bar.transactionChip) && menus == 1, "a click asks for the chip's menu")
    f.bar.showTransaction(.failed)
    expect(f.bar.transactionChip.title == "Transaction failed" && f.bar.transactionChip.contentTintColor == .systemRed,
           "failed: red")
    expect(f.bar.transactionChip.accessibilityIdentifier() == "editor.context.transaction", "AX id")
}

@MainActor
private func testContextMenu() {
    let f = Fixture()
    f.layout()
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: f.window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
    let menu = f.bar.menu(for: event)
    let titles = menu?.items.map(\.title) ?? []
    expect(titles == ["Rename Tab…", "Duplicate Tab"], "a right-click offers Rename Tab… and Duplicate Tab", "\(titles)")
    f.bar.offersSaveAsConnection = true
    let withSave = f.bar.menu(for: event)?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
    expect(withSave == ["Rename Tab…", "Duplicate Tab", "—", "Save as Connection"],
           "an opened file's tab also offers Save as Connection", "\(withSave)")
    expect(f.bar.menu(for: event)?.items.last?.action == NSSelectorFromString("menuSaveAsConnection:"),
           "by name, to the content controller")
    f.bar.offersSaveAsConnection = false
    expect(menu?.items.first?.action == NSSelectorFromString("menuRenameTab:") && menu?.items.first?.target == nil,
           "Rename goes up the responder chain to menuRenameTab:")
    // The content controller must still answer to these names; the shell
    // script checks ContentViewController.swift for each.
}

@MainActor
private func testNoConflicts() {
    let before = SpyWindow.conflicts
    let wide = Fixture()
    wide.bar.showConnections([group("PostgreSQL", [coda, billing])], selectedId: "c1")
    wide.bar.showState(.failed(reason: "x"))
    wide.bar.showTransaction(.failed)
    wide.layout()
    let narrow = Fixture(width: 0)
    narrow.bar.showConnections([group("PostgreSQL", [coda])], selectedId: "c1")
    narrow.bar.showState(.connected)
    narrow.layout()
    expect(SpyWindow.conflicts == before, "no constraint conflicts, wide or at width 0",
           "\(SpyWindow.conflicts - before) reported")
}

func runTests() {
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
    MainActor.assumeIsolated {
        testConnections()
        testFileLocations()
        testStates()
        testSchema()
        testChip()
        testContextMenu()
        testNoConflicts()
    }
    if failures == 0 { print("\nAll tab context bar tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
