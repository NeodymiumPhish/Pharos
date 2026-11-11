// Standalone test for VariableManagerVC (in the manager shell) and
// VariableConnectionsView — compiled by scripts/test-variable-manager.sh.
// Real AppKit in a window ordered in offscreen at (-20000, -20000), so field
// editors and the toolbar exist.
//
// Covers what the old list's row-layout harness (since removed) covered:
// what each row says (title, subtitle, warning), plus the settle / prune /
// collision rules, the toolbar, Delete and Duplicate, the Connections box,
// the store-republish rule (lessons, 2026-09-16) and constraint conflicts.
import AppKit

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let text = detail()
        print("FAIL \(name)" + (text.isEmpty ? "" : "\n  \(text)"))
    }
}

/// Counts constraint conflicts: with the default
/// NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints on, AppKit
/// calls `visualizeConstraints(_:)` on every conflict, transient ones too
/// (scripts/test-constraint-swap.sh).
private final class SpyWindow: NSWindow {
    static var conflicts = 0
    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        if !(constraints ?? []).isEmpty { Self.conflicts += 1 }
    }
}

@MainActor
private final class Host {
    let window = SpyWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
    let vc = VariableManagerVC()
    var written: [[QueryVariable]] = []
    /// The counts `confirmBulkDelete` was asked with, and its answer.
    var bulkDeleteAsks: [Int] = []
    var bulkDeleteAnswer = true

    init(_ variables: [QueryVariable]) {
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosVariableManagerSplit")
        vc.setSort(.added)
        vc.setSortAscending(true)
        vc.confirmBulkDelete = { [unowned self] count, _, proceed in
            self.bulkDeleteAsks.append(count)
            if self.bulkDeleteAnswer { proceed() }
        }
        window.isReleasedWhenClosed = false
        vc.onChange = { [unowned self] in self.written.append($0) }
        vc.choicesProvider = { _ in [
            .init(id: "prod", name: "Prod", place: "app on db:5432", kind: .server, state: .connected, missing: false),
            .init(id: "sales", name: "sales", place: "~/sales.duckdb", kind: .file, state: .disconnected, missing: false),
        ] }
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 860, height: 560))
        vc.installToolbar(on: window)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        vc.setVariables(variables)
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosVariableManagerSplit")
    }

    var last: [QueryVariable] { written.last ?? vc.variables }

    func item(_ id: UUID) -> ManagerSidebarItem? {
        vc.sidebar.items.first { $0.id == id.uuidString }
    }

    /// A click on the variable's row, through the table's own selection path.
    func click(_ id: UUID) {
        guard let row = vc.sidebar.shownItems.firstIndex(where: { $0.id == id.uuidString }) else { return }
        vc.sidebar.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// ⌘-clicks on these variables' rows: the table's own selection path.
    func clickMany(_ ids: [UUID]) {
        let wanted = Set(ids.map(\.uuidString))
        let rows = IndexSet(vc.sidebar.shownItems.indices.filter { wanted.contains(vc.sidebar.shownItems[$0].id) })
        vc.sidebar.tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// The context menu a right-click on the variable's row opens.
    func contextMenu(on id: UUID) -> NSMenu {
        let menu = NSMenu()
        if let row = vc.sidebar.shownItems.firstIndex(where: { $0.id == id.uuidString }) {
            vc.sidebar.populateContextMenu(menu, forRow: row)
        }
        return menu
    }

    var shownNames: [String] { vc.sidebar.shownItems.map(\.title) }

    /// Types into a field through its real field editor.
    func type(_ text: String, into field: NSTextField) {
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            expectTrue(false, "setup: \(field.accessibilityIdentifier()) has a field editor")
            return
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
}

// MARK: - Sidebar rows

@MainActor
private func testSidebarRows() {
    let env = QueryVariable(name: "env", value: "prod")
    let limit = QueryVariable(name: "limit", value: "50", type: .number)
    let bad = QueryVariable(name: "port", value: "4x", type: .number)
    let day = QueryVariable(name: "day", value: "today", type: .date)
    let fixedDay = QueryVariable(name: "start", value: "2026-10-28", type: .date)
    let ids = QueryVariable(name: "ids", value: "a\nb\n\nc", type: .textList)
    let blank = QueryVariable(name: "  ", value: "x")
    let linked = QueryVariable(name: "region", value: "eu", type: .text, connectionIds: ["prod", "sales"])
    let flag = QueryVariable(name: "flag", value: "t", type: .bool)
    let stamp = QueryVariable(name: "at", value: "now", type: .timestamptz)
    let empty = QueryVariable(name: "nothing", value: "")
    let host = Host([env, limit, bad, day, fixedDay, ids, blank, linked, flag, stamp, empty])
    defer { host.close() }

    expect(host.vc.sidebar.items.count, 11, "rows: one per variable")
    expect(host.vc.sidebar.tableView.numberOfRows, 11, "rows: and the table shows them all")
    expect(host.item(env.id)?.title, "{{env}}", "title: the name in braces")
    expect(host.item(env.id)?.titleIsMonospaced, true, "title: monospaced")
    expect(host.item(blank.id)?.title, "Untitled", "title: a blank name reads Untitled")
    expect(host.item(blank.id)?.titleIsMonospaced, false, "title: Untitled is a word, not a token")

    expect(host.item(env.id)?.subtitle, "Literal · prod", "subtitle: type · value")
    expect(host.item(limit.id)?.subtitle, "Number · 50", "subtitle: Number · 50")
    expect(host.item(day.id)?.subtitle, "Date · Today", "subtitle: a relative date reads Today")
    expect(host.item(fixedDay.id)?.subtitle, "Date · 2026-10-28", "subtitle: a fixed date shows the date")
    expect(host.item(ids.id)?.subtitle, "List · 3 items", "subtitle: a list counts its items (blank lines skipped)")
    expect(host.item(linked.id)?.subtitle, "Text · eu · 2 connections", "subtitle: a linked variable names its connection count")
    expect(host.item(flag.id)?.subtitle, "Bool · True", "subtitle: a Bool shows its choice")
    expect(host.item(stamp.id)?.subtitle, "Timestamp · Now", "subtitle: a relative timestamp reads Now")
    expect(host.item(empty.id)?.subtitle, "Literal · No value", "subtitle: an empty value says so")

    // Problems show in the Manager for every variable, referenced or not.
    guard case .invalidValue(let reason)? = VariableSubstitutor.problem(for: bad) else {
        fatalError("fixture: the bad Number must be invalid")
    }
    let message = VariableDetailVC.invalidSentence(reason)
    expect(host.item(bad.id)?.trailing, [.warning(tooltip: message)], "warning: a bad Number carries its problem")
    expectTrue(message.contains("not a valid number"), "warning: and the message says why", message)
    expectTrue(!message.contains("Referenced"), "warning: the Manager does not claim the query uses it", message)
    expect(host.item(empty.id)?.trailing.count, 1, "warning: an empty Literal is flagged too")
    expect(host.item(env.id)?.trailing, [], "warning: a healthy variable has none")
    expect(host.item(day.id)?.trailing, [], "warning: nor does a relative date")

    // The detail agrees with the row: the same rowStates pass.
    host.click(bad.id)
    expect(host.vc.detailVC?.nameField.textColor, NSColor.systemRed, "detail: the bad variable's name is red")
    expect(host.vc.detailVC?.nameField.toolTip, message, "detail: with the same message")

    // An edit in the form updates its row in place.
    host.type("443", into: host.vc.detailVC!.numberField)
    expect(host.item(bad.id)?.subtitle, "Number · 443", "row: follows the value as it is typed")
    expect(host.item(bad.id)?.trailing, [], "row: and its warning goes when the value is fixed")
}

// MARK: - The manager's rules

@MainActor
private func testManagerFlow() {
    let env = QueryVariable(name: "env", value: "prod")
    let limit = QueryVariable(name: "limit", value: "50", type: .number)
    let host = Host([env, limit])
    defer { host.close() }

    expect(host.vc.selectedId, nil, "nothing selected at first")
    host.click(env.id)
    expect(host.vc.selectedId, env.id, "a click on a row opens it in the detail")
    expect(host.vc.detailVC?.variable.name, "env", "the detail shows that variable")
    expectTrue(host.vc.split.detail === host.vc.detailVC, "the form is the split view's detail")

    // The Connections box is in the form, below the Value box.
    host.layout()
    if let detail = host.vc.detailVC {
        expectTrue(host.vc.connectionsView.isDescendant(of: detail.view), "Connections: in the detail form")
        let header = allDescendants(of: detail.view).first { $0.accessibilityIdentifier() == "settings.section.connections" }
        expectTrue(header != nil, "Connections: under its own section header")
        if let valueBox = detail.rendersAsRow?.superview {
            let box = valueBox.convert(valueBox.bounds, to: nil)
            let connections = host.vc.connectionsView.convert(host.vc.connectionsView.bounds, to: nil)
            expectTrue(connections.maxY <= box.minY, "Connections: below the Value box",
                       "connections \(connections), value box \(box)")
            expectTrue(connections.width > 300, "Connections: as wide as the form, not a 300 pt side column",
                       "width \(connections.width)")
        }
    }

    // Linking: choosing "Only these" with nothing ticked keeps it global.
    host.vc.connectionsView.chooseSome()
    expect(host.vc.variables.first { $0.id == env.id }?.connectionIds, [], "no box ticked yet: still global")
    host.vc.connectionsView.tick("prod", true)
    expect(host.last.first { $0.id == env.id }?.connectionIds, ["prod"], "ticking a connection links the variable")
    host.vc.connectionsView.tick("sales", true)
    expect(host.last.first { $0.id == env.id }?.connectionIds, ["prod", "sales"], "and a second one")
    expect(host.item(env.id)?.subtitle, "Literal · prod · 2 connections", "the row says how many")

    // A value edit in the detail keeps the links set since it opened.
    var edited = host.vc.detailVC!.variable
    edited.value = "staging"
    host.vc.detailVC!.onChange?(edited)
    let after = host.last.first { $0.id == env.id }
    expect(after?.value, "staging", "the value edit lands")
    expect(after?.connectionIds, ["prod", "sales"], "and the links are not lost to the form's copy")

    host.vc.connectionsView.chooseAll()
    expect(host.last.first { $0.id == env.id }?.connectionIds, [], "All connections clears the links")
    expect(host.vc.connectionsView.isGlobalChosen, true, "and the radio says so")

    // Another row re-reads its own links.
    host.click(limit.id)
    expect(host.vc.connectionsView.tickedIds, [], "a global variable has nothing ticked")

    // + (the toolbar) adds a row and opens it; leaving it empty drops it.
    let addItem = host.window.toolbar?.items.first { $0.itemIdentifier == .pharosManagerAdd }
    expect(addItem?.label, "New Variable", "toolbar: + is New Variable")
    if let addItem, let action = addItem.action { NSApp.sendAction(action, to: addItem.target, from: addItem) }
    let added = host.vc.selectedId
    expectTrue(added != nil && added != limit.id, "+ opens a new row")
    expect(host.vc.variables.count, 3, "with a third variable")
    expect(host.vc.sidebar.selectedId, added?.uuidString, "and the sidebar selects it")
    host.click(env.id)
    expect(host.vc.variables.count, 2, "an abandoned empty row is dropped on leaving it")

    // The toolbar's filter filters the sidebar.
    host.vc.toolbarController.filterField.stringValue = "lim"
    _ = host.vc.toolbarController.filterField.sendAction(host.vc.toolbarController.filterField.action,
                                                         to: host.vc.toolbarController.filterField.target)
    expect(host.vc.sidebar.shownItems.map(\.id), [limit.id.uuidString], "filter: the field filters the rows")
    host.vc.applyFilter("")
    expect(host.vc.sidebar.shownItems.count, 2, "filter: cleared, every row is back")

    // A token click: an existing name opens; a new one is made.
    host.vc.openVariable(named: "limit")
    expect(host.vc.selectedId, limit.id, "an existing name opens its variable")
    host.vc.openVariable(named: "region")
    expect(host.vc.detailVC?.variable.name, "region", "a new name makes a variable with it")
    expect(host.vc.variables.count, 3, "added to the list")

    // Delete from the sidebar (the Delete key's path): the form closes.
    let regionId = host.vc.selectedId!
    expectTrue(host.vc.sidebar.deleteSelectedRows(), "Delete: the sidebar deletes the selected row")
    expect(host.vc.selectedId, nil, "deleting the open variable closes the detail")
    expect(host.vc.variables.map(\.name), ["env", "limit"], "and removes it")
    expectTrue(host.vc.variables.allSatisfy { $0.id != regionId }, "by id")

    // The form's own Delete button.
    host.click(limit.id)
    if let button = host.vc.detailVC?.deleteButton, let action = button.action {
        expect(button.hasDestructiveAction, true, "Delete Variable: a destructive button")
        NSApp.sendAction(action, to: button.target, from: button)
    }
    expect(host.vc.variables.map(\.name), ["env"], "Delete Variable deletes the open variable")

    // Duplicate, from the sidebar's menu.
    host.vc.sidebar.onDuplicate?(env.id.uuidString)
    expect(host.vc.variables.map(\.name), ["env", "env_copy"], "Duplicate: env_copy, just below env")
    expect(host.vc.detailVC?.variable.name, "env_copy", "Duplicate: and opens the copy")
    expect(host.vc.variables[1].value, "staging", "Duplicate: with the value")
    host.vc.sidebar.onDuplicate?(env.id.uuidString)
    expect(host.vc.variables.map(\.name), ["env", "env_copy2", "env_copy"], "Duplicate: a taken name gets a number")
    let menu = NSMenu()
    host.vc.sidebar.populateContextMenu(menu, forRow: 0)
    expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["AI Apps", "Duplicate", "Delete"],
           "context menu: AI Apps, Duplicate and Delete")

    // Another surface's edit: the selection stays when its variable is there.
    host.click(env.id)
    var external = host.vc.variables
    external[0].value = "changed elsewhere"
    host.vc.setVariables(external)
    expect(host.vc.selectedId, env.id, "an outside edit keeps the selection")
    expect(host.vc.variables[0].value, "changed elsewhere", "and adopts the edit")
    expect(host.vc.detailVC?.variable.value, "changed elsewhere", "the form shows it while nobody types in it")
}

// MARK: - Collision refusal across rows

@MainActor
private func testCollisionRefusesRowSwitch() {
    let env = QueryVariable(name: "env", value: "prod")
    let limit = QueryVariable(name: "limit", value: "50", type: .number)
    let host = Host([env, limit])
    defer { host.close() }

    host.click(env.id)
    guard let detail = host.vc.detailVC else { return expectTrue(false, "setup: env opens") }
    host.type("limit", into: detail.nameField)
    expect(detail.isNameCollision, true, "typing an existing name collides")
    expect(host.vc.variables[0].name, "env", "and is not committed")
    host.click(limit.id)
    expect(host.vc.selectedId, env.id, "a colliding name refuses to leave its row")
    expect(host.vc.sidebar.selectedId, env.id.uuidString, "and the sidebar's selection goes back to it")
    host.type("envy", into: detail.nameField)
    host.click(limit.id)
    expect(host.vc.selectedId, limit.id, "a unique name leaves")
    expect(host.vc.variables[0].name, "envy", "and commits on the way out")
}

// MARK: - The store's republish does not eat an edit

@MainActor
private func testRepublishLeavesTheFormAlone() {
    let env = QueryVariable(name: "env", value: "prod")
    let limit = QueryVariable(name: "limit", value: "50", type: .number)
    let host = Host([env, limit])
    defer { host.close() }

    host.click(env.id)
    guard let detail = host.vc.detailVC else { return expectTrue(false, "setup: env opens") }
    host.type("environment", into: detail.nameField)

    // Another surface writes the store: a different variable changes, and
    // this one's value too.
    var external = host.vc.variables
    external[1].value = "99"
    external[0].value = "from elsewhere"
    host.vc.setVariables(external)
    expectTrue(host.vc.detailVC === detail, "republish: the same form stays up")
    expect(host.vc.detailVC?.nameField.stringValue, "environment", "republish: the name being typed survives")
    expect(host.vc.detailVC?.variable.value, "prod", "republish: the form being typed in is not overwritten")
    expect(host.item(limit.id)?.subtitle, "Number · 99", "republish: the sidebar follows at once")
}

// MARK: - Constraint conflicts

@MainActor
private func testNoConstraintConflicts() {
    let before = SpyWindow.conflicts
    let variables = [
        QueryVariable(name: "lit", value: "a\nb"),
        QueryVariable(name: "num", value: "4x", type: .number),
        QueryVariable(name: "flag", value: "true", type: .bool),
        QueryVariable(name: "day", value: "2026-10-28", type: .date),
        QueryVariable(name: "at", value: "2026-10-28 10:00:00 Europe/Paris", type: .timestamptz),
        QueryVariable(name: "ids", value: "1\n2", type: .numberList),
    ]
    let host = Host(variables)
    defer { host.close() }
    for variable in variables {
        host.click(variable.id)
        host.layout()
    }
    host.window.setContentSize(NSSize(width: 720, height: 440))
    host.layout()
    expectTrue(host.vc.split.splitViewItems[1].viewController.view.frame.width >= VariableManagerVC.detailMinimum - 0.5,
               "layout: at the 720 pt minimum the detail keeps its 460 pt",
               "detail \(host.vc.split.splitViewItems[1].viewController.view.frame.width)")
    expect(SpyWindow.conflicts - before, 0, "layout: no constraint conflict for any type, at any size")
}

/// The first + once pulled the window from 860 to 780 pt and the sidebar
/// from 220 to its 320 maximum: "Renders as" hugged its text, and the row's
/// unmet span squeezed the form, and the window with it, against the detail's
/// 460 pt minimum. No form, of any type, may move either.
@MainActor
private func testFormKeepsWindowAndSidebarWidths() {
    let host = Host([])
    defer { host.close() }
    func widths() -> (window: CGFloat, sidebar: CGFloat) {
        host.layout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layout()
        return (host.window.frame.width, host.vc.split.splitViewItems[0].viewController.view.frame.width)
    }
    let before = widths()
    expect(before.sidebar, ManagerSplitViewController.sidebarMinimum, "widths: the sidebar opens at 220 pt")
    host.vc.addVariable()
    let added = widths()
    expect(added.window, before.window, "widths: + keeps the window's width")
    expect(added.sidebar, before.sidebar, "widths: + keeps the sidebar's width")
    let variables = [
        QueryVariable(name: "short", value: "42"),
        QueryVariable(name: "num", value: "4x", type: .number),
        QueryVariable(name: "day", value: "2026-10-28", type: .date),
        QueryVariable(name: "today", value: "today", type: .date),
        QueryVariable(name: "at", value: "2026-10-28 10:00:00 Europe/Paris", type: .timestamptz),
        QueryVariable(name: "flag", value: "true", type: .bool),
        QueryVariable(name: "ids", value: "1\n2", type: .numberList),
        QueryVariable(name: String(repeating: "a_long_variable_name_", count: 6),
                      value: String(repeating: "a long value ", count: 20), type: .text),
    ]
    host.vc.setVariables(variables)
    for variable in variables {
        host.click(variable.id)
        let now = widths()
        expect(now.window, before.window, "widths: \(variable.type.rawValue) \(variable.value.prefix(12)) keeps the window's width")
        expect(now.sidebar, before.sidebar, "widths: \(variable.type.rawValue) \(variable.value.prefix(12)) keeps the sidebar's width")
    }
}

/// No variables at all: "No Variables" and New Variable, as the Tag Manager
/// says "No Tags". Variables but none open: "No Variable Selected".
@MainActor
private func testEmptyStates() {
    let host = Host([])
    defer { host.close() }
    let empty = host.vc.emptyStateVC.emptyState
    expectTrue(host.vc.split.detail === host.vc.emptyStateVC, "empty: with no variables the empty state is the detail")
    expect(empty.titleText, "No Variables", "empty: with none it says No Variables")
    expectTrue(empty.messageText.contains("{{name}}"), "empty: and says what a variable is (\(empty.messageText))")
    let button = empty.actionButtonForTesting
    expectTrue(!button.isHidden, "empty: it offers a button")
    expect(button.title, "New Variable", "empty: New Variable")
    button.performClick(nil)
    host.layout()
    expect(host.vc.variables.count, 1, "empty: New Variable makes a variable")
    expectTrue(host.vc.detailVC != nil && host.vc.split.detail === host.vc.detailVC, "empty: and opens its form")
    if let id = host.vc.variables.first?.id { host.vc.deleteVariable(id) }
    host.layout()
    expect(empty.titleText, "No Variables", "empty: deleting the last one says No Variables again")
    expectTrue(!empty.actionButtonForTesting.isHidden, "empty: with its button")

    host.vc.setVariables([QueryVariable(name: "env", value: "prod")])
    host.layout()
    expectTrue(host.vc.split.detail === host.vc.emptyStateVC, "empty: variables but none open → still the empty state")
    expect(empty.titleText, "No Variable Selected", "empty: which asks for a pick")
    expectTrue(empty.actionButtonForTesting.isHidden, "empty: with no button")
    host.vc.setVariables([])
    host.layout()
    expect(empty.titleText, "No Variables", "empty: another window deleting them all says No Variables")
}

@MainActor
private func testMissingChoice() {
    let view = VariableConnectionsView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
    var heard: [[String]] = []
    view.onChange = { heard.append($0) }
    view.show(choices: [.init(id: "gone", name: "", place: "", kind: .file, state: .none, missing: true)], linked: ["gone"])
    expect(view.isGlobalChosen, false, "a linked variable shows Only these connections")
    expect(view.tickedIds, ["gone"], "its missing connection is ticked")
    view.tick("gone", false)
    expect(heard.last, [], "unticking the missing one removes the link (global again)")
}

@MainActor
private func testCopyName() {
    expect(VariableManagerVC.copyName(for: "a", taken: ["a"]), "a_copy", "copy name: _copy")
    expect(VariableManagerVC.copyName(for: " a ", taken: ["a", "a_copy", "a_copy2"]), "a_copy3",
           "copy name: trimmed, and numbered past the taken ones")
}

// MARK: - AI apps, bulk edit, sort and filter

private func titles(_ menu: NSMenu?) -> [String] {
    (menu?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title }
}

private func choose(_ title: String, in menu: NSMenu?) {
    guard let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else {
        expectTrue(false, "setup: the menu has \(title)")
        return
    }
    menu.performActionForItem(at: index)
}

@MainActor
private func testAIAccessChoice() {
    let token = QueryVariable(name: "token", value: "s3cret", type: .text)
    let day = QueryVariable(name: "day", value: "today", type: .date, mcpAccess: .all)
    let host = Host([token, day])
    defer { host.close() }

    expect(host.item(token.id)?.trailing, [], "row: a variable that is Off carries no AI mark")
    expect(host.item(day.id)?.trailing, [.symbol(name: "sparkles", label: "AI apps: All approved AI apps")],
           "row: one shared with all approved AI apps is marked")

    host.click(token.id)
    host.layout()
    guard let detail = host.vc.detailVC else { return expectTrue(false, "setup: the form opened") }
    expect(detail.aiAccessPopup.itemTitles, ["Off", "Local AI apps only", "All approved AI apps"],
           "form: the AI apps choices, as a connection has")
    expect(detail.aiAccessPopup.titleOfSelectedItem, "Off", "form: a variable starts Off")
    expectTrue(detail.aiAccessRow?.window != nil, "form: the AI apps row is in the window")

    detail.aiAccessPopup.selectItem(at: 1)
    if let action = detail.aiAccessPopup.action { NSApp.sendAction(action, to: detail.aiAccessPopup.target, from: detail.aiAccessPopup) }
    expect(host.last.first?.mcpAccess, .local, "form: choosing Local AI apps only is written")
    expect(host.item(token.id)?.trailing, [.symbol(name: "laptopcomputer", label: "AI apps: Local AI apps only")],
           "row: and its row is marked for local apps")
    expect(host.last.first?.value, "s3cret", "form: the choice leaves the value alone")

    // The form's later edits keep the choice.
    host.type("other", into: detail.nameField)
    host.window.makeFirstResponder(nil)
    detail.settleForDismissal()
    expect(host.last.first?.mcpAccess, .local, "form: a rename keeps the AI apps choice")

    // Another surface's change reaches the pop-up.
    var external = host.vc.variables
    external[0].mcpAccess = .all
    host.vc.setVariables(external)
    expect(detail.aiAccessPopup.titleOfSelectedItem, "All approved AI apps", "form: an outside change shows in the pop-up")
    expect(detail.variable.mcpAccess, .all, "form: and the form's own copy has it")

    // The row's context menu sets it too, with a tick on the current choice.
    let menu = host.contextMenu(on: token.id)
    let submenu = menu.items.first { $0.title == "AI Apps" }?.submenu
    expect(titles(submenu), ["Off", "Local AI apps only", "All approved AI apps"], "menu: AI Apps lists the three choices")
    expect(submenu?.items.map(\.state), [.off, .off, .on], "menu: the current choice is ticked")
    choose("Off", in: submenu)
    expect(host.last.first?.mcpAccess, .off, "menu: choosing Off is written")
    expect(detail.aiAccessPopup.titleOfSelectedItem, "Off", "menu: and the open form follows")

    // A copy keeps the choice: it holds the same value.
    host.vc.setAIAccess(.local, for: [token.id])
    host.vc.duplicateVariable(token.id)
    expect(host.vc.variables.map(\.mcpAccess), [.local, .local, .all], "Duplicate: the copy keeps the AI apps choice")
}

@MainActor
private func testBulkEditAndDelete() {
    let a = QueryVariable(name: "a", value: "1", type: .number)
    let b = QueryVariable(name: "b", value: "2", type: .number, mcpAccess: .all)
    let c = QueryVariable(name: "c", value: "x", type: .text)
    let d = QueryVariable(name: "d", value: "y", type: .text)
    let host = Host([a, b, c, d])
    defer { host.close() }

    expect(host.vc.sidebar.tableView.allowsMultipleSelection, true, "sidebar: several rows can be selected")
    host.click(a.id)
    host.layout()
    expectTrue(host.vc.detailVC != nil, "setup: one row opens its form")

    host.clickMany([a.id, b.id, c.id])
    host.layout()
    expect(host.vc.multiSelectedIds, [a.id, b.id, c.id], "select many: the three rows are the selection")
    expectTrue(host.vc.detailVC == nil, "select many: the form closes")
    expect(host.vc.selectedId, nil, "select many: no single variable is open")
    expect(host.vc.emptyStateVC.emptyState.titleText, "3 Variables Selected", "select many: the detail says how many")
    expect(host.vc.sidebar.tableView.selectedRowIndexes, IndexSet([0, 1, 2]), "select many: the rows stay selected")

    // The selection's menu: no Duplicate, and Delete names the count.
    var menu = host.contextMenu(on: b.id)
    expect(titles(menu), ["AI Apps", "—", "Delete 3 Variables"], "menu: a selection gets AI Apps and Delete 3 Variables")
    var submenu = menu.items.first?.submenu
    expect(submenu?.items.map(\.state), [.mixed, .off, .mixed], "menu: a choice only some have shows a dash")

    let writesBefore = host.written.count
    choose("Local AI apps only", in: submenu)
    expect(host.vc.variables.map(\.mcpAccess), [.local, .local, .local, .off], "bulk edit: every selected variable gets the choice")
    expect(host.written.count, writesBefore + 1, "bulk edit: written once")
    expect(host.vc.multiSelectedIds, [a.id, b.id, c.id], "bulk edit: the selection stays")
    expect(host.vc.sidebar.tableView.selectedRowIndexes, IndexSet([0, 1, 2]), "bulk edit: and so do its rows")
    submenu = host.contextMenu(on: a.id).items.first?.submenu
    expect(submenu?.items.map(\.state), [.off, .on, .off], "menu: once they agree, the choice is ticked")
    choose("Local AI apps only", in: submenu)
    expect(host.written.count, writesBefore + 1, "bulk edit: the choice they already have writes nothing")

    // A right-click outside the selection acts on that row alone.
    menu = host.contextMenu(on: d.id)
    expect(titles(menu), ["AI Apps", "—", "Duplicate", "—", "Delete"], "menu: a row outside the selection gets its own menu")
    choose("All approved AI apps", in: menu.items.first?.submenu)
    expect(host.vc.variables.map(\.mcpAccess), [.local, .local, .local, .all], "menu: and changes only that row")

    // Delete asks once for several, and does nothing on Cancel.
    host.bulkDeleteAnswer = false
    choose("Delete 3 Variables", in: host.contextMenu(on: a.id))
    expect(host.bulkDeleteAsks, [3], "bulk delete: asks, with the count")
    expect(host.vc.variables.count, 4, "bulk delete: Cancel deletes nothing")

    host.bulkDeleteAnswer = true
    let writes = host.written.count
    expectTrue(host.vc.sidebar.deleteSelectedRows(), "bulk delete: the Delete key acts on the selection")
    expect(host.bulkDeleteAsks, [3, 3], "bulk delete: the Delete key asks too")
    expect(host.vc.variables.map(\.name), ["d"], "bulk delete: the three are gone")
    expect(host.written.count, writes + 1, "bulk delete: written once")
    expect(host.vc.multiSelectedIds, [], "bulk delete: nothing is selected after")
    expect(host.vc.emptyStateVC.emptyState.titleText, "No Variable Selected", "bulk delete: the detail asks for a pick again")

    // One row is still deleted at once.
    choose("Delete", in: host.contextMenu(on: d.id))
    expect(host.bulkDeleteAsks, [3, 3], "delete: one variable does not ask")
    expect(host.vc.variables.count, 0, "delete: and goes")
}

@MainActor
private func testMultiSelectionRules() {
    let a = QueryVariable(name: "a", value: "1")
    let b = QueryVariable(name: "b", value: "2")
    let c = QueryVariable(name: "c", value: "3")
    let host = Host([a, b, c])
    defer { host.close() }

    // Back to one row: its form opens.
    host.clickMany([a.id, b.id])
    host.click(c.id)
    host.layout()
    expect(host.vc.multiSelectedIds, [], "one row after several: the selection of several ends")
    expect(host.vc.detailVC?.variable.name, "c", "one row after several: its form opens")

    // A colliding name refuses to leave for a selection of several.
    host.type("a", into: host.vc.detailVC!.nameField)
    host.clickMany([a.id, b.id])
    host.layout()
    expect(host.vc.multiSelectedIds, [], "collision: a selection of several is refused")
    expect(host.vc.selectedId, c.id, "collision: the form stays")
    expect(host.vc.sidebar.selectedId, c.id.uuidString, "collision: and the sidebar goes back to its row")
    host.type("c", into: host.vc.detailVC!.nameField)

    // Another surface deleting part of the selection.
    host.clickMany([a.id, b.id, c.id])
    host.vc.setVariables([a, c])
    expect(host.vc.multiSelectedIds, [a.id, c.id], "outside delete: the selection keeps what is left")
    host.vc.setVariables([c])
    expect(host.vc.multiSelectedIds, [], "outside delete: one left is no longer a selection of several")
}

@MainActor
private func testSortAndFilter() {
    let zeta = QueryVariable(name: "zeta", value: "1", type: .number, mcpAccess: .all)
    let alpha = QueryVariable(name: "alpha", value: "x", type: .text)
    let mid = QueryVariable(name: "Mid", value: "2", type: .number, mcpAccess: .local)
    let day = QueryVariable(name: "day", value: "today", type: .date, mcpAccess: .all)
    let all = [zeta, alpha, mid, day]

    // The rule itself.
    var options = VariableListOptions()
    expect(options.apply(to: all).map(\.name), ["zeta", "alpha", "Mid", "day"], "options: the stored order by default")
    options.sort = .name
    expect(options.apply(to: all).map(\.name), ["alpha", "day", "Mid", "zeta"], "options: by name, ignoring case")
    options.ascending = false
    expect(options.apply(to: all).map(\.name), ["zeta", "Mid", "day", "alpha"], "options: by name, descending")
    options = VariableListOptions(sort: .type)
    expect(options.apply(to: all).map(\.name), ["alpha", "Mid", "zeta", "day"], "options: by type (the pop-up's order), then name")
    options.ascending = false
    expect(options.apply(to: all).map(\.name), ["day", "Mid", "zeta", "alpha"], "options: by type descending keeps names in order")
    options = VariableListOptions(sort: .aiApps)
    expect(options.apply(to: all).map(\.name), ["alpha", "Mid", "day", "zeta"], "options: by AI apps: Off, Local, All")
    options = VariableListOptions(sort: .added, ascending: false)
    expect(options.apply(to: all).map(\.name), ["day", "Mid", "alpha", "zeta"], "options: the stored order, newest first")
    options = VariableListOptions(typeFilter: .number)
    expect(options.apply(to: all).map(\.name), ["zeta", "Mid"], "options: only Numbers")
    options.aiFilter = .local
    expect(options.apply(to: all).map(\.name), ["Mid"], "options: both filters apply")
    expect(options.isFiltering, true, "options: a filter is on")
    expect(VariableListOptions(sort: .name).isFiltering, false, "options: a sort alone hides nothing")
    let unnamed = QueryVariable(name: " ", value: "")
    expect(VariableListOptions(sort: .name).apply(to: [unnamed, alpha]).map(\.name), ["alpha", " "], "options: an unnamed row sorts last")

    // In the window.
    let host = Host(all)
    defer {
        host.vc.setSort(.added)
        host.vc.setSortAscending(true)
        host.close()
    }
    let toolbar = host.window.toolbar
    expectTrue(toolbar?.items.contains { $0.itemIdentifier == .pharosManagerOptions } == true, "toolbar: has the Sort and Filter menu")
    let optionsItem = toolbar?.items.first { $0.itemIdentifier == .pharosManagerOptions } as? NSMenuToolbarItem
    expectTrue(optionsItem?.menu === host.vc.optionsMenu, "toolbar: the item shows the manager's menu")
    expect(optionsItem?.label, "Sort and Filter", "toolbar: named Sort and Filter")
    let ids = toolbar?.items.map(\.itemIdentifier) ?? []
    if let o = ids.firstIndex(of: .pharosManagerOptions), let plus = ids.firstIndex(of: .pharosManagerAdd),
       let sep = ids.firstIndex(of: .pharosManagerSidebarSeparator) {
        expectTrue(o < plus && plus < sep, "toolbar: the menu sits beside +, over the sidebar")
    } else {
        expectTrue(false, "toolbar: the menu, + and the separator are all there")
    }

    expect(host.shownNames, ["{{zeta}}", "{{alpha}}", "{{Mid}}", "{{day}}"], "sidebar: the stored order first")
    let menu = host.vc.optionsMenu
    expect(titles(menu), ["Sort By", "Order Added", "Name", "Type", "AI Apps", "—", "Ascending", "Descending",
                          "Filter", "Type", "AI Apps", "—", "Clear Filters"], "menu: Sort By, the direction, Filter")
    expect(menu.items.first { $0.title == "Order Added" }?.state, .on, "menu: the current order is ticked")
    expect(menu.items.last?.isEnabled, false, "menu: Clear Filters is off while nothing is filtered")

    choose("Name", in: menu)
    host.layout()
    expect(host.shownNames, ["{{alpha}}", "{{day}}", "{{Mid}}", "{{zeta}}"], "sort: by name")
    expect(host.vc.variables.map(\.name), ["zeta", "alpha", "Mid", "day"], "sort: the stored order is untouched")
    expect(host.written.count, 0, "sort: nothing is written")
    expect(menu.items.first { $0.title == "Name" }?.state, .on, "menu: Name is ticked")
    choose("Descending", in: menu)
    expect(host.shownNames, ["{{zeta}}", "{{Mid}}", "{{day}}", "{{alpha}}"], "sort: descending")
    expect(VariableListOptions.restored().sort, .name, "sort: the order is remembered")
    expect(VariableListOptions.restored().ascending, false, "sort: and its direction")
    host.vc.setSort(.name)
    expect(host.vc.listOptions.ascending, true, "sort: choosing the same order again turns it round")
    expect(optionsItem?.image?.accessibilityDescription, "Sort and Filter", "toolbar: the menu button has a label")
    expect(host.vc.toolbarController.optionsAreActive, false, "toolbar: a sort alone does not mark the button")

    // The selection survives a sort.
    host.click(day.id)
    choose("AI Apps", in: menu)
    host.layout()
    expect(host.shownNames, ["{{alpha}}", "{{Mid}}", "{{day}}", "{{zeta}}"], "sort: by AI apps choice")
    expect(host.vc.selectedId, day.id, "sort: the open variable stays open")
    expect(host.vc.sidebar.tableView.selectedRow, 2, "sort: and its row stays selected in its new place")

    // Filters.
    let typeMenu = menu.items.first { $0.title == "Type" && $0.submenu != nil }?.submenu
    expect(titles(typeMenu), ["All Types", "—", "Literal", "Text", "Number", "Bool", "Date", "Timestamp", "List"], "filter: the types")
    choose("Number", in: typeMenu)
    host.layout()
    expect(host.shownNames, ["{{Mid}}", "{{zeta}}"], "filter: only Numbers, still sorted")
    expect(host.vc.toolbarController.optionsAreActive, true, "toolbar: a filter marks the button")
    expect(host.vc.selectedId, day.id, "filter: hiding the open variable's row keeps its form")
    expect(host.vc.optionsMenu.items.last?.isEnabled, true, "menu: Clear Filters is on")
    expect(VariableListOptions.restored().typeFilter, nil, "filter: not remembered")

    let appsMenu = host.vc.optionsMenu.items.last { $0.title == "AI Apps" && $0.submenu != nil }?.submenu
    expect(titles(appsMenu), ["Any Choice", "—", "Off", "Local AI apps only", "All approved AI apps"], "filter: the AI apps choices")
    choose("Off", in: appsMenu)
    host.layout()
    expect(host.vc.sidebar.isShowingNoMatches, true, "filter: nothing matches both → No Matches")
    host.vc.setTypeFilter(nil)
    expect(host.shownNames, ["{{alpha}}"], "filter: only the variables that are Off")

    // The text filter narrows what the menu's filters left.
    host.vc.setAIFilter(.all)
    host.vc.applyFilter("zet")
    expect(host.shownNames, ["{{zeta}}"], "filter: the filter field applies as well")
    host.vc.applyFilter("")

    // A bulk edit under a filter: the rows that leave the filter leave the list.
    host.clickMany([zeta.id, day.id])
    host.vc.setAIAccess(.off, for: host.vc.multiSelectedIds)
    host.layout()
    expect(host.vc.sidebar.isShowingNoMatches, true, "filter: rows that no longer match leave the list")
    choose("Clear Filters", in: host.vc.optionsMenu)
    expect(host.vc.sidebar.shownItems.count, 4, "Clear Filters: every variable is back")
    expect(host.vc.toolbarController.optionsAreActive, false, "Clear Filters: the button is plain again")

    // An empty list under a filter says No Variables, not No Matches.
    host.vc.setTypeFilter(.bool)
    host.vc.setVariables([])
    expect(host.vc.sidebar.isShowingNoMatches, false, "filter: with no variables at all there is nothing to match")
}

private func allDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants(of: $0) }
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
    MainActor.assumeIsolated {
        testNoConstraintConflicts()
        testFormKeepsWindowAndSidebarWidths()
        testEmptyStates()
        testSidebarRows()
        testManagerFlow()
        testCollisionRefusesRowSwitch()
        testRepublishLeavesTheFormAlone()
        testMissingChoice()
        testCopyName()
        testAIAccessChoice()
        testBulkEditAndDelete()
        testMultiSelectionRules()
        testSortAndFilter()
    }
    if failures == 0 { print("\nAll variable manager tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
