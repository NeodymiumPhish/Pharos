# Schema Selector Scrollable Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the editor's schema-selector `NSMenu` with a searchable, naturally-scrolling `NSPopover` list so a long schema list (50-100 entries) scrolls like every other list in the app instead of jumping in large increments.

**Architecture:** A pure filter helper (`SchemaListFilter`, unit-tested standalone) backs a self-contained popover view controller (`SchemaSelectorPopoverVC`) containing a search field + `NSScrollView`/`NSTableView`. A tiny `NSPopUpButton` subclass (`SchemaPopUpButton`) keeps the existing toolbar look but presents the popover on click instead of the native menu. `EditorPaneVC` swaps the control type, trims the menu-building code, and wires the popover's callbacks to its existing `setTabSchema(_:)` / set-default logic.

**Tech Stack:** Swift / AppKit, XcodeGen (`project.yml` globs the `Pharos/` directory), Rust core via FFI (unaffected). Pure-logic tests via standalone `swiftc` harness (no Xcode test target).

---

## File Structure

- **Create** `Pharos/Editor/SchemaListFilter.swift` — pure, AppKit-free filtering for the schema list. Testable standalone.
- **Create** `PharosTests/SchemaListFilterTests.swift` — standalone tests for the filter.
- **Create** `scripts/test-schema-list-filter.sh` — harness runner (mirrors `scripts/test-sql-list-formatter.sh`).
- **Create** `Pharos/ViewControllers/SchemaSelectorPopoverVC.swift` — popover content (search + scrollable table). Knows nothing about `EditorPaneVC`.
- **Create** `Pharos/Views/SchemaPopUpButton.swift` — `NSPopUpButton` subclass that presents the popover instead of the native menu.
- **Modify** `Pharos/ViewControllers/EditorPaneVC.swift` — change `schemaPopup` type, trim `rebuildSchemaMenu()`, wire the popover, remove the now-dead `schemaItemClicked(_:)`.

Note: `PharosTests/main.swift` already exists and calls `runTests()`. Each standalone harness defines its own `runTests()`, so only ONE harness can be compiled with that shim at a time — that matches the existing single-harness pattern.

---

### Task 1: Pure schema-list filter + standalone test

**Files:**
- Create: `Pharos/Editor/SchemaListFilter.swift`
- Test: `PharosTests/SchemaListFilterTests.swift`
- Create: `scripts/test-schema-list-filter.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/SchemaListFilterTests.swift`:

```swift
// Standalone test runner for SchemaListFilter. Not part of the app target —
// compiled together with the implementation by scripts/test-schema-list-filter.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let schemas = ["public", "analytics", "Reporting", "audit_log", "billing"]

    expectEqual(SchemaListFilter.filter(schemas, query: ""), schemas,
        "empty query returns all, order preserved")
    expectEqual(SchemaListFilter.filter(schemas, query: "   "), schemas,
        "whitespace-only query returns all")
    expectEqual(SchemaListFilter.filter(schemas, query: "log"), ["audit_log"],
        "substring match (not just prefix)")
    expectEqual(SchemaListFilter.filter(schemas, query: "REPORT"), ["Reporting"],
        "case-insensitive match")
    expectEqual(SchemaListFilter.filter(schemas, query: "i"), ["analytics", "Reporting", "audit_log", "billing"],
        "multiple matches keep original order")
    expectEqual(SchemaListFilter.filter(schemas, query: "zzz"), [],
        "no match returns empty")
    expectEqual(SchemaListFilter.filter(schemas, query: "  bill  "), ["billing"],
        "query is trimmed before matching")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s).") ; exit(1) }
}
```

- [ ] **Step 2: Create the harness script**

Create `scripts/test-schema-list-filter.sh`:

```bash
#!/bin/bash
# Standalone test runner for SchemaListFilter — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/schema-list-filter-tests \
  Pharos/Editor/SchemaListFilter.swift \
  PharosTests/SchemaListFilterTests.swift \
  PharosTests/main.swift
/tmp/schema-list-filter-tests
```

Then make it executable:

```bash
chmod +x scripts/test-schema-list-filter.sh
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/test-schema-list-filter.sh`
Expected: FAIL — compile error, `cannot find 'SchemaListFilter' in scope` (the implementation file does not exist yet).

- [ ] **Step 4: Write minimal implementation**

Create `Pharos/Editor/SchemaListFilter.swift`:

```swift
import Foundation

/// Pure filtering for the schema selector list. No AppKit dependencies —
/// unit-tested standalone via scripts/test-schema-list-filter.sh.
enum SchemaListFilter {

    /// Case-insensitive substring filter over schema names, preserving the
    /// original order. An empty or whitespace-only query returns all schemas
    /// unchanged.
    static func filter(_ schemas: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return schemas }
        return schemas.filter { $0.lowercased().contains(q) }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test-schema-list-filter.sh`
Expected: PASS — every line prints `PASS …` and final `All tests passed.`

- [ ] **Step 6: Commit**

```bash
git add Pharos/Editor/SchemaListFilter.swift PharosTests/SchemaListFilterTests.swift scripts/test-schema-list-filter.sh
git commit -m "feat: pure SchemaListFilter for schema selector with standalone tests"
```

---

### Task 2: SchemaSelectorPopoverVC (popover content)

**Files:**
- Create: `Pharos/ViewControllers/SchemaSelectorPopoverVC.swift`

This is an AppKit view controller; it cannot be exercised by the pure-logic harness. Verification is via the integration build in Task 5 and manual testing. Its only logic dependency, the filter, is already tested in Task 1.

- [ ] **Step 1: Create the view controller**

Create `Pharos/ViewControllers/SchemaSelectorPopoverVC.swift`:

```swift
import AppKit

/// Popover content for the editor's schema selector. A search field sits above a
/// scrollable list of schemas, so it scrolls naturally (unlike NSMenu, which jumps
/// in large increments). A pinned "All Schemas" row sits at the top; the active
/// schema shows a checkmark and the connection's default schema shows a
/// "★ default" badge. Single-click commits a selection; the owner dismisses the
/// popover. Self-contained — knows nothing about EditorPaneVC.
final class SchemaSelectorPopoverVC: NSViewController {

    /// Fired when a schema row is clicked. `nil` means "All Schemas".
    var onSelectSchema: ((String?) -> Void)?
    /// Fired when "Set as Default Schema" is clicked.
    var onSetDefault: (() -> Void)?

    private let allSchemas: [String]
    private let activeSchema: String?
    private let defaultSchema: String?

    private var visibleSchemas: [String]

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    init(schemas: [String], activeSchema: String?, defaultSchema: String?) {
        self.allSchemas = schemas
        self.activeSchema = activeSchema
        self.defaultSchema = defaultSchema
        self.visibleSchemas = schemas
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Search field — live filtering via controlTextDidChange.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter schemas\u{2026}"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        container.addSubview(searchField)

        // Table inside a scroll view — natural scrolling.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("schema"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let setDefaultButton = NSButton(
            title: "Set as Default Schema", target: self, action: #selector(setDefaultClicked))
        setDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.controlSize = .small
        setDefaultButton.font = .systemFont(ofSize: 12)
        container.addSubview(setDefaultButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 240),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.heightAnchor.constraint(equalToConstant: 220),

            setDefaultButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            setDefaultButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            setDefaultButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            setDefaultButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if row == 0 {
            onSelectSchema?(nil)            // "All Schemas"
        } else {
            let idx = row - 1
            guard idx < visibleSchemas.count else { return }   // stale-index guard
            onSelectSchema?(visibleSchemas[idx])
        }
    }

    @objc private func setDefaultClicked() {
        onSetDefault?()
    }
}

extension SchemaSelectorPopoverVC: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        visibleSchemas = SchemaListFilter.filter(allSchemas, query: searchField.stringValue)
        tableView.reloadData()
    }
}

extension SchemaSelectorPopoverVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleSchemas.count + 1   // +1 for the pinned "All Schemas" row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("schemaRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.imageView = iv
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let title: String
        let isActive: Bool
        if row == 0 {
            title = "All Schemas"
            isActive = (activeSchema == nil)
        } else {
            let name = visibleSchemas[row - 1]
            title = (name == defaultSchema) ? "\(name)  \u{2605} default" : name
            isActive = (activeSchema == name)
        }
        cell.textField?.stringValue = title
        cell.imageView?.image = isActive
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "selected")
            : nil
        cell.toolTip = title
        return cell
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Pharos/ViewControllers/SchemaSelectorPopoverVC.swift
git commit -m "feat: SchemaSelectorPopoverVC searchable scrollable schema list"
```

---

### Task 3: SchemaPopUpButton (presents popover instead of native menu)

**Files:**
- Create: `Pharos/Views/SchemaPopUpButton.swift`

- [ ] **Step 1: Create the subclass**

Create `Pharos/Views/SchemaPopUpButton.swift`:

```swift
import AppKit

/// An NSPopUpButton that presents a custom popover instead of its native menu,
/// while keeping the standard recessed/borderless arrow appearance so it matches
/// the adjacent connection popup. The native menu carries only the current title
/// item (set by the owner), so keyboard activation degrades gracefully to showing
/// that single item rather than an empty menu.
final class SchemaPopUpButton: NSPopUpButton {

    /// Invoked on a mouse click when the control is enabled. The owner uses this
    /// to present the schema popover anchored to `self`.
    var onActivate: ((SchemaPopUpButton) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let onActivate else {
            super.mouseDown(with: event)
            return
        }
        onActivate(self)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Pharos/Views/SchemaPopUpButton.swift
git commit -m "feat: SchemaPopUpButton subclass that opens a popover on click"
```

---

### Task 4: Wire the popover into EditorPaneVC

**Files:**
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`

- [ ] **Step 1: Change the schemaPopup type**

In `Pharos/ViewControllers/EditorPaneVC.swift`, find (line ~44):

```swift
    private let schemaPopup = NSPopUpButton(frame: .zero, pullsDown: true)
```

Replace with:

```swift
    private let schemaPopup = SchemaPopUpButton(frame: .zero, pullsDown: true)
```

- [ ] **Step 2: Add a stored popover property**

Immediately below the `schemaSpinner` property declaration (line ~45):

```swift
    private let schemaSpinner = NSProgressIndicator()
```

add:

```swift
    private var schemaPopover: NSPopover?
```

- [ ] **Step 3: Wire the activation closure**

Find the schema popup configuration block (lines ~485-489):

```swift
        // Schema popup (right side)
        schemaPopup.bezelStyle = .recessed
        schemaPopup.isBordered = false
        schemaPopup.controlSize = .small
        schemaPopup.translatesAutoresizingMaskIntoConstraints = false
        (schemaPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
```

Add this line directly after it:

```swift
        schemaPopup.onActivate = { [weak self] button in
            self?.presentSchemaPopover(from: button)
        }
```

- [ ] **Step 4: Trim rebuildSchemaMenu to only set the title**

Replace the body from `schemaPopup.isEnabled = true` through the end of the `setDefaultItem` block (lines ~805-844):

```swift
        schemaPopup.isEnabled = true

        // Get default schema for the active connection
        let defaultSchema: String? = {
            guard let connId = tabConnectionId else { return nil }
            return stateManager.connections.first(where: { $0.id == connId })?.defaultSchema
        }()

        let titleText = activeSchema ?? "All Schemas"
        schemaPopup.addItem(withTitle: titleText)

        let allItem = NSMenuItem(title: "All Schemas", action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = nil
        if activeSchema == nil { allItem.state = .on }
        schemaPopup.menu?.addItem(allItem)

        schemaPopup.menu?.addItem(.separator())

        for schema in schemas {
            var title = schema.name
            if schema.name == defaultSchema {
                title += "  \u{2605} default"  // ★ default
            }
            let item = NSMenuItem(title: title, action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = schema.name
            if activeSchema == schema.name { item.state = .on }
            schemaPopup.menu?.addItem(item)
        }

        // Separator + "Set as Default Schema" action
        schemaPopup.menu?.addItem(.separator())
        let setDefaultItem = NSMenuItem(
            title: "Set as Default Schema",
            action: #selector(setDefaultSchemaClicked),
            keyEquivalent: ""
        )
        setDefaultItem.target = self
        schemaPopup.menu?.addItem(setDefaultItem)
```

with:

```swift
        schemaPopup.isEnabled = true

        // The button shows a single title item; the full schema list and the
        // "All Schemas" / "Set as Default" actions now live in the popover
        // (see presentSchemaPopover), which scrolls naturally for long lists.
        let titleText = activeSchema ?? "All Schemas"
        schemaPopup.addItem(withTitle: titleText)
```

Note: the `schemas` local (from `let schemas = metadataCache.schemas`) and `activeSchema` are still read earlier in the function for the connected/empty guard and the title — leave that part untouched.

- [ ] **Step 5: Add presentSchemaPopover and remove the dead schemaItemClicked**

Find `schemaItemClicked` (lines ~940-942):

```swift
    @objc private func schemaItemClicked(_ sender: NSMenuItem) {
        setTabSchema(sender.representedObject as? String)
    }
```

Replace it with the popover presenter (it no longer needs to be an `@objc` menu action; selection now flows through the popover's callbacks into the existing `setTabSchema(_:)`):

```swift
    /// Build and present the searchable schema popover anchored to the schema
    /// button. Selection and set-default flow back through the existing
    /// setTabSchema / setDefaultSchemaClicked logic.
    private func presentSchemaPopover(from button: NSView) {
        let schemaNames = metadataCache.schemas.map { $0.name }
        let defaultSchema: String? = {
            guard let connId = tabConnectionId else { return nil }
            return stateManager.connections.first(where: { $0.id == connId })?.defaultSchema
        }()

        let vc = SchemaSelectorPopoverVC(
            schemas: schemaNames,
            activeSchema: tabSchemaName,
            defaultSchema: defaultSchema
        )
        vc.onSelectSchema = { [weak self] schema in
            self?.setTabSchema(schema)
            self?.schemaPopover?.close()
        }
        vc.onSetDefault = { [weak self] in
            self?.setDefaultSchemaClicked()
            self?.schemaPopover?.close()
        }

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        schemaPopover = popover
    }
```

Leave `setDefaultSchemaClicked` and `setTabSchema(_:)` unchanged — they are reused. `setDefaultSchemaClicked` keeps its trailing `rebuildSchemaMenu()` call, which refreshes the button title after the default changes.

- [ ] **Step 6: Verify no remaining references to schemaItemClicked**

Run: `grep -n "schemaItemClicked" Pharos/ViewControllers/EditorPaneVC.swift`
Expected: no output (the only definition and its `#selector` uses were removed).

- [ ] **Step 7: Commit**

```bash
git add Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "feat: present scrollable schema popover from EditorPaneVC, drop schema NSMenu items"
```

---

### Task 5: Regenerate project, build, and verify

**Files:** none (build + manual verification)

- [ ] **Step 1: Regenerate the Xcode project**

New Swift files must be added to the project before building.

Run: `xcodegen generate`
Expected: `Generated project at Pharos.xcodeproj` (or similar success line), no errors.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: ends with `** BUILD SUCCEEDED **`. (The Rust pre-build step runs automatically; first build may be slow.)

- [ ] **Step 3: Re-run the filter unit tests (regression)**

Run: `./scripts/test-schema-list-filter.sh`
Expected: PASS — `All tests passed.`

- [ ] **Step 4: Manual verification (Cmd+R in Xcode)**

Connect to a database with many schemas (ideally 50-100) and confirm:
- [ ] Clicking the schema selector opens a popover (not a native menu) with a search field and a scrollable list.
- [ ] Scrolling the list with a mouse wheel / trackpad advances smoothly, one notch at a time — no large jumps to the bottom. **This is the core fix.**
- [ ] Typing in the search field filters the list live (case-insensitive substring).
- [ ] The currently active schema shows a checkmark; the connection's default schema shows the `★ default` badge.
- [ ] Clicking a schema selects it, updates the toolbar title, and closes the popover.
- [ ] The pinned "All Schemas" row clears the schema filter.
- [ ] "Set as Default Schema" sets the current schema as the connection default (badge updates on reopen).
- [ ] The toolbar appearance is unchanged next to the connection popup.
- [ ] Disconnected / no-schema state shows "No Schema" disabled; loading shows "Loading…" — the popover does not open in those states.

- [ ] **Step 5: Final commit (if any manual-fix tweaks were needed)**

```bash
git add -A
git commit -m "chore: regenerate project for schema selector popover"
```

(If no files changed in this step, skip the commit.)

---

## Self-Review Notes

- **Spec coverage:** scrollable list (Task 2 scroll view), search (Task 2 search field + Task 1 filter), "All Schemas" (Task 2 pinned row + Task 4 `setTabSchema(nil)`), `★ default` badge + active checkmark (Task 2 cell), "Set as Default" (Task 4 reused `setDefaultSchemaClicked`), unchanged toolbar look (Task 3 keeps `NSPopUpButton` chrome), disabled/loading states (Task 4 keeps existing guard/`updateSchemaLoading`). All covered.
- **Type consistency:** `onActivate`, `onSelectSchema`, `onSetDefault`, `SchemaSelectorPopoverVC(schemas:activeSchema:defaultSchema:)`, `SchemaListFilter.filter(_:query:)`, `presentSchemaPopover(from:)`, `schemaPopover` used identically across tasks.
- **No placeholders:** every code step shows complete code; commands have expected output.
