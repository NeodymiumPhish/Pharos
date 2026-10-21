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

/// C1: a DuckDB item says where its file is, and "File not found" when the
/// menu opens on a file that is gone.
@MainActor
private func testFileLocations() {
    let f = Fixture()
    let popUp = f.bar.connectionPopUp
    let sales = TabContextBar.ConnectionItem(id: "d1", name: "sales", state: .disconnected,
                                             location: "~/Data/sales.duckdb", filePath: "/Users/x/Data/sales.duckdb",
                                             isDuckDB: true)
    let open = TabContextBar.ConnectionItem(id: "d2", name: "open", state: .connected,
                                            location: "~/open.duckdb", filePath: "/Users/x/open.duckdb", isDuckDB: true)
    let mem = TabContextBar.ConnectionItem(id: "d3", name: "scratch", state: .connected, location: "In-memory",
                                           isDuckDB: true)
    f.bar.fileExists = { _ in false }
    f.bar.showConnections([coda, sales, open, mem], selectedId: "d1")
    let item = popUp.itemArray.first { $0.title == "sales" }
    expect(item?.subtitle == "Not connected · ~/Data/sales.duckdb", "the subtitle is the state, then the location",
           item?.subtitle ?? "nil")
    expect(item?.toolTip == "/Users/x/Data/sales.duckdb", "the tooltip is the full path")
    expect(popUp.itemArray.first { $0.title == "scratch" }?.subtitle == "Connected · In-memory", "in-memory says so")
    expect(popUp.itemArray.first { $0.title == "Coda" }?.subtitle == "Connected", "a server keeps the state alone")
    let headers = popUp.itemArray.filter(\.isSectionHeader).map(\.title)
    expect(headers == ["PostgreSQL", "DuckDB"], "both engines: a header for each", "\(headers)")
    f.bar.markMissingFiles()
    expect(item?.subtitle == "File not found · ~/Data/sales.duckdb", "a gone file says so when the menu opens",
           item?.subtitle ?? "nil")
    expect(popUp.itemArray.first { $0.title == "open" }?.subtitle == "Connected · ~/open.duckdb",
           "an open file is never marked missing")
    f.bar.showConnections([sales], selectedId: "d1")
    expect(!popUp.itemArray.contains(where: \.isSectionHeader), "one engine: no headers")
}

@MainActor
private func testConnections() {
    let f = Fixture()
    let popUp = f.bar.connectionPopUp
    f.bar.showConnections([coda, billing], selectedId: "c1")
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

    f.bar.showConnections([coda, billing], selectedId: nil)
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
private func testNoConflicts() {
    let before = SpyWindow.conflicts
    let wide = Fixture()
    wide.bar.showConnections([coda, billing], selectedId: "c1")
    wide.bar.showState(.failed(reason: "x"))
    wide.bar.showTransaction(.failed)
    wide.layout()
    let narrow = Fixture(width: 0)
    narrow.bar.showConnections([coda], selectedId: "c1")
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
        testNoConflicts()
    }
    if failures == 0 { print("\nAll tab context bar tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
