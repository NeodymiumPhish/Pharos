# Database Navigator Display Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Database Navigator roomier two-line rows, move the partition strategy badge to the trailing edge of the title line, and make the Inspector show detail for every schema-browser selection (regular tables/views and columns, not just partition-related nodes).

**Architecture:** Purely presentational + Inspector wiring. Two independent changes: (1) a cell/row-metrics refactor in `SchemaTreeCellView` + `SchemaBrowserVC`; (2) new Inspector render methods + an expanded selection router. No data/model changes; the partition backend, sorting, filtering, and "Show Leaf Partitions" gating are untouched.

**Tech Stack:** Swift/AppKit (`NSTableCellView`, `NSStackView`, Auto Layout, `NSOutlineView`). No unit-test harness applies (AppKit view/VC code, per `pharos-swift-test-harness`); each task ends with a build + a live `/verify` pass.

---

## File Structure

- `Pharos/Views/SchemaTreeCellView.swift` — MODIFY (Task 1): spacing, subtitle/icon sizing, revert the badge's `primaryRow` wrapper, reposition the badge to a trailing sibling with a constraint swap.
- `Pharos/ViewControllers/SchemaBrowserVC.swift` — MODIFY (Task 1: `rowHeight`; Task 2: selection router).
- `Pharos/ViewControllers/InspectorViewController.swift` — MODIFY (Task 2): add `showTableDetail`, `showColumnDetail`.

No new files. `SchemaTreeNode.partitionBadge` and `PartitionStrategy.badgeLabel` both stay (still used).

---

## Task 1: Roomier rows + right-aligned strategy badge

**Files:**
- Modify: `Pharos/Views/SchemaTreeCellView.swift`
- Modify: `Pharos/ViewControllers/SchemaBrowserVC.swift` (`outlineView.rowHeight`)

**Context:** The cell currently wraps `primaryLabel` + `badgeLabel` in a horizontal `primaryRow` sub-stack (so the badge sits inline after the title), stacks that over `secondaryLabel` with `labelStack.spacing = 0`, uses a 10pt subtitle and a 16pt icon, inside a 38pt row. This task: bump the row to 44pt, add a 3pt title/subtitle gap, 11pt subtitle, 18pt icon, and move the badge to a right-aligned trailing sibling aligned to the title line (title/subtitle truncate before it). Keep `renderBadge()` (pill styling + selected-state contrast) and the import-glow logic.

- [ ] **Step 1: Bump the row height**

In `Pharos/ViewControllers/SchemaBrowserVC.swift`, change the row height line (currently `outlineView.rowHeight = 38`):

```swift
        outlineView.rowHeight = 44
```

- [ ] **Step 2: Restructure the cell's layout in `init`**

In `Pharos/Views/SchemaTreeCellView.swift`, add two stored properties for the trailing-constraint swap near the other properties (after `private let labelStack = NSStackView()`):

```swift
    /// Active when a partition badge is shown: label stack stops before the badge.
    private var labelStackTrailingToBadge: NSLayoutConstraint!
    /// Active when no badge: label stack extends to the cell's trailing edge.
    private var labelStackTrailingToCell: NSLayoutConstraint!
```

In `init`, replace the badge/label-stack assembly and constraints. The current code builds a `primaryRow` horizontal stack and a single `labelStack.trailingAnchor` constraint. Replace the block that begins at `labelStack.orientation = .vertical` through the end of the `NSLayoutConstraint.activate([...])` call with:

```swift
        labelStack.orientation = .vertical
        labelStack.spacing = 3
        labelStack.alignment = .leading
        labelStack.addArrangedSubview(primaryLabel)
        labelStack.addArrangedSubview(secondaryLabel)
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)
        addSubview(badgeLabel)

        labelStackTrailingToBadge = labelStack.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -6)
        labelStackTrailingToCell = labelStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Badge pinned to the trailing edge, aligned to the TITLE line (not row center).
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: primaryLabel.centerYAnchor),
        ])
        // Default (no badge) trailing constraint; configure() swaps as needed.
        labelStackTrailingToCell.isActive = true
```

(Keep the earlier `badgeLabel.font/.wantsLayer/.layer?.cornerRadius/.isHidden` setup and the `primaryLabel`/`secondaryLabel` property setup that precede this block — only the assembly/constraints change. Also update `secondaryLabel.font` in that setup: see Step 3.)

- [ ] **Step 3: Bump the subtitle font to 11pt (init + attributed rendering)**

In `init`, change the secondary label font:

```swift
        secondaryLabel.font = .systemFont(ofSize: 11)
```

In `renderSecondaryText()`, the importing-suffix path builds an attributed string with two `NSFont.systemFont(ofSize: 10)` uses — bump both to 11 so the importing state matches:

```swift
        let attributed = NSMutableAttributedString(
            string: base,
            attributes: [
                .foregroundColor: baseColor,
                .font: NSFont.systemFont(ofSize: 11),
            ]
        )
        let separator = base.isEmpty || base == " " ? "" : " \u{00B7} "
        attributed.append(NSAttributedString(
            string: separator + importing,
            attributes: [
                .foregroundColor: importColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ]
        ))
```

- [ ] **Step 4: Toggle the trailing-constraint swap in `configure(node:)`**

In `configure(node:)`, the badge branch currently sets `badgeLabel.stringValue`/`isHidden`/`renderBadge()`. Replace that `if let badge = node.partitionBadge { ... } else { ... }` block with a version that also swaps the label-stack trailing constraint:

```swift
        if let badge = node.partitionBadge {
            badgeLabel.stringValue = " \(badge) "
            badgeLabel.isHidden = false
            labelStackTrailingToCell.isActive = false
            labelStackTrailingToBadge.isActive = true
            renderBadge()
        } else {
            badgeLabel.isHidden = true
            labelStackTrailingToBadge.isActive = false
            labelStackTrailingToCell.isActive = true
        }
```

- [ ] **Step 5: Reset the constraint swap in `prepareForReuse()`**

In `prepareForReuse()`, alongside the existing `badgeLabel.isHidden = true` / `badgeLabel.stringValue = ""`, restore the no-badge constraint state so a recycled cell starts clean:

```swift
        badgeLabel.isHidden = true
        badgeLabel.stringValue = ""
        labelStackTrailingToBadge.isActive = false
        labelStackTrailingToCell.isActive = true
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. If Auto Layout complains at runtime about the two `lessThanOrEqualTo` trailing constraints, note that only one is ever active at a time (Step 4/5 guarantee this) — a build error here means a typo, not a constraint conflict.

- [ ] **Step 7: Commit**

```bash
git add Pharos/Views/SchemaTreeCellView.swift Pharos/ViewControllers/SchemaBrowserVC.swift
git commit -m "feat: roomier navigator rows + right-aligned strategy badge"
```

- [ ] **Step 8: Manual verify (`/verify`, live app)**

Rebuild in Xcode. Confirm: rows are visibly roomier (title/subtitle gap, 11pt subtitle, 18pt icon, 44pt rows); column name/type lines no longer cramped; a partitioned parent shows its RANGE/LIST/HASH pill right-aligned on the title line, clear of the subtitle, with correct color when the row is selected; a long table name truncates before the pill; a non-partitioned table shows no pill and its title extends to the trailing edge; scrolling a partitioned table's 200+ partitions shows no stray/leftover badges on recycled rows.

---

## Task 2: Inspector detail for regular tables/views and columns

**Files:**
- Modify: `Pharos/ViewControllers/InspectorViewController.swift` (add two methods)
- Modify: `Pharos/ViewControllers/SchemaBrowserVC.swift` (`schemaDataSourceSelectionDidChange`)

**Context:** `InspectorViewController` already renders detail sections via `beginDetailSection(title:subtitle:)`, `addDetailField(_:_:color:)`, `formatRowCount(_:)`, and `formatByteSize(_:)`, and has `showPartitionedTableDetail`/`showPartitionDetail`/`showNoSelection`. Today `SchemaBrowserVC.schemaDataSourceSelectionDidChange` only routes partition-related kinds; regular tables/views and columns fall to `default: break` (blank/stale Inspector). This task adds two render methods mirroring the existing style and routes every node kind. `TableInfo` has `name`, `schemaName`, `tableType` (`.table`/`.view`/`.foreignTable`/`.partitionedTable`), `rowCountEstimate`, `totalSizeBytes`. `ColumnInfo` has `name`, `dataType`, `isNullable`, `isPrimaryKey`, `ordinalPosition`, `columnDefault`.

- [ ] **Step 1: Add `showTableDetail` and `showColumnDetail` to `InspectorViewController`**

In `Pharos/ViewControllers/InspectorViewController.swift`, add these two methods right after `showPartitionDetail(_:parentName:)` (which ends around line 167). Type is conveyed by the section header (mirroring how `showPartitionedTableDetail` uses "Partitioned Table" as the header rather than a separate field), so there is no redundant "Type" field:

```swift
    /// Shows detail for a regular (non-partitioned) table, view, or foreign table.
    func showTableDetail(_ info: TableInfo) {
        let category: String
        switch info.tableType {
        case .view: category = "View"
        case .foreignTable: category = "Foreign Table"
        case .partitionedTable: category = "Partitioned Table"
        case .table: category = "Table"
        }
        beginDetailSection(title: category, subtitle: info.name)

        addDetailField("Schema", info.schemaName)
        addDetailField("Rows", formatRowCount(info.rowCountEstimate))
        if info.totalSizeBytes != nil {
            addDetailField("Size", formatByteSize(info.totalSizeBytes))
        }
    }

    /// Shows detail for a selected column. `parentName` is the enclosing
    /// table/partition name, when known.
    func showColumnDetail(_ info: ColumnInfo, parentName: String?) {
        beginDetailSection(title: "Column", subtitle: info.name)

        if let parentName {
            addDetailField("Table", parentName)
        }
        addDetailField("Type", info.dataType)
        addDetailField("Nullable", info.isNullable ? "Yes" : "No")
        addDetailField("Primary key", info.isPrimaryKey ? "Yes" : "No")
        if let columnDefault = info.columnDefault, !columnDefault.isEmpty {
            addDetailField("Default", columnDefault)
        }
    }
```

- [ ] **Step 2: Route every node kind in the selection handler**

In `Pharos/ViewControllers/SchemaBrowserVC.swift`, replace the body of `schemaDataSourceSelectionDidChange(_:)` (the `switch node.kind { ... default: break }` currently at lines ~740-749) with an exhaustive router:

```swift
        switch node.kind {
        case .table(let info) where info.isPartitioned:
            splitVC.inspectorVC.showPartitionedTableDetail(info)
        case .table(let info), .view(let info):
            splitVC.inspectorVC.showTableDetail(info)
        case .partitionGroup(let parentInfo):
            splitVC.inspectorVC.showPartitionedTableDetail(parentInfo)
        case .partition(let info):
            splitVC.inspectorVC.showPartitionDetail(info, parentName: node.parent?.tableName)
        case .column(let info):
            splitVC.inspectorVC.showColumnDetail(info, parentName: node.parent?.tableName)
        case .schema:
            splitVC.inspectorVC.showNoSelection()
        case .loading:
            break
        }
```

(Keep the two `guard` lines above it — `guard let splitVC = parent?.parent as? PharosSplitViewController else { return }` and `guard let node else { return }` — unchanged. The `where info.isPartitioned` case must stay ABOVE the combined `.table, .view` case so partitioned parents route to the partition detail; the general case then catches all remaining tables and all views. `Kind` is now matched exhaustively, so no `default` is needed.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. If the compiler flags the `switch` as non-exhaustive or the combined `case .table(let info), .view(let info)` binding, confirm both associated values are `TableInfo` (they are) — the shared `let info` binding is valid because both cases carry the same type.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/InspectorViewController.swift Pharos/ViewControllers/SchemaBrowserVC.swift
git commit -m "feat: inspector shows detail for regular tables/views and columns"
```

- [ ] **Step 5: Manual verify (`/verify`, live app)**

Reveal the Inspector (collapsed by default). Confirm: selecting a **regular table** shows a "Table" section with Schema / Rows / Size; a **view** shows "View" with Schema / Rows (no Size); a **column** shows "Column" with Table / Type / Nullable / Primary key / Default (Default omitted when the column has none); a **partitioned parent**, **partition**, and **partition group** still show their existing detail; selecting a **schema** node clears the panel to "No selection". Selecting a table in the schema tree correctly takes the panel over from any prior results-grid detail.

---

## Self-Review Notes

- **Spec coverage:** §1 row layout → Task 1 Steps 1-3 (rowHeight 44, spacing 3, subtitle 11, icon 18). §2 badge right-aligned → Task 1 Steps 2,4,5 (trailing sibling + constraint swap, `renderBadge` retained). §3 Inspector → Task 2 (both new methods + full routing table incl. schema→clear, loading/nil→no-op).
- **Deviation from spec (documented):** the spec listed "Type" as a field for `showTableDetail`; the implementation puts the type in the section header instead (consistent with the existing `showPartitionedTableDetail`/`showPartitionDetail` pattern where the category is the header, not a field) — the type is still shown, just not duplicated.
- **Type consistency:** `showTableDetail(_:)`, `showColumnDetail(_:parentName:)`, and the existing `showPartitionedTableDetail`/`showPartitionDetail`/`showNoSelection` signatures match their call sites in the router. `node.parent?.tableName` is the existing accessor used for the partition parent name.
- **No pure-logic tests:** presentational/VC wiring only; verification is build + live `/verify` per task, consistent with the project's no-AppKit-test-target constraint.
