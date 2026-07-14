# Database Navigator Display Refinement — Design

**Date:** 2026-07-14
**Status:** Approved for planning
**Area:** Schema browser cell rendering (`SchemaTreeCellView`), row metrics (`SchemaBrowserVC`), tree node (`SchemaTreeNode`), Inspector (`InspectorViewController`)

## Problem

Live use of the partition-aware navigator surfaced presentation issues:

1. **Cramped rows.** The cell stacks a 13pt title directly over a 10pt subtitle with `labelStack.spacing = 0` inside a fixed 38pt row. Titles and their sublines (and column name/type lines) visually touch.
2. **Cluttered title line.** The `RANGE`/`LIST`/`HASH` strategy pill sits inline immediately after the table name, crowding the title.
3. **Incomplete Inspector.** The schema browser only populates the Inspector for partition-related selections (partitioned parent, partition, partition group). Selecting a plain (non-partitioned) table/view or a column does nothing — the Inspector stays blank/stale.

## Goal

Give navigator rows breathing room, move the strategy badge out of the title's way (kept, right-aligned), and make the Inspector show useful detail for **every** schema-browser selection (regular tables/views and columns included).

## Non-Goals

- No change to what data is fetched or how the tree is built. Purely presentational + Inspector wiring.
- No variable row heights (the fixed `rowHeight` is a deliberate performance optimization for very large schemas; keep it).
- No change to the "Show Leaf Partitions" gating, sorting, or filtering behavior.

## Design

### 1. Row layout — roomier two-line (`SchemaTreeCellView.swift`, `SchemaBrowserVC.swift`)

- `SchemaBrowserVC`: `outlineView.rowHeight` **38 → 44** (uniform fixed height retained).
- `SchemaTreeCellView`:
  - `labelStack.spacing` **0 → 3** — the core de-cramp; title and subtitle no longer touch.
  - `secondaryLabel` font **10 → 11pt** (keeps `.secondaryLabelColor`). De-cramps both table sublines and column type lines.
  - `iconView` **16 → 18pt** to balance the taller row. (Adjust the icon width/height constraints from 16 to 18.)
  - `primaryLabel` stays **13pt**.

Tradeoff (accepted): 44pt rows show fewer rows at once — more scrolling for large partition sets. 44 was chosen from visual comparison; it is a single-constant tweak if it needs nudging later.

### 2. Strategy badge — kept, right-aligned on the title line (`SchemaTreeCellView.swift`)

The badge (`node.partitionBadge` → RANGE/LIST/HASH) stays but moves from inline-after-title to the trailing edge:

- Remove the `primaryRow` horizontal wrapper (`[primaryLabel, badgeLabel]`). `primaryLabel` becomes a direct arranged subview of the vertical `labelStack` again (title over subtitle).
- Add `badgeLabel` as a **sibling subview** of the cell (not inside `labelStack`), pinned to `trailingAnchor` and vertically aligned to the **title line** (align badge to `primaryLabel`'s vertical center, not the row center, so it clears the subtitle).
- Constrain `labelStack.trailingAnchor <= badgeLabel.leadingAnchor - 6` when the badge is visible, and `labelStack.trailingAnchor <= trailingAnchor - 4` when it is not — a two-constraint swap toggled in `configure`/`prepareForReuse` by whether `node.partitionBadge` is non-nil, with `badgeLabel.trailingAnchor = trailingAnchor - 8`. (This mirrors the constraint-swap pattern previously used for the now-removed sort toggle.)
- Keep `renderBadge()` (accent pill + selected-state contrast) and its `backgroundStyle` `didSet` hook, and the `prepareForReuse` resets.
- `SchemaTreeNode.partitionBadge` **stays** (still the badge's data source).

Non-partitioned tables have `partitionBadge == nil` → no badge, `labelStack` extends to the trailing edge.

### 3. Inspector — detail for all schema selections (`InspectorViewController.swift`, `SchemaBrowserVC.swift`)

Expand `SchemaBrowserVC.schemaDataSourceSelectionDidChange(_:)` to route every node kind to the Inspector (reached via the existing `parent?.parent as? PharosSplitViewController` path):

| Selected node | Inspector shows |
|---|---|
| `.table`/`.view` where `isPartitioned` | `showPartitionedTableDetail` (existing) |
| `.table`/`.view` (regular) | **`showTableDetail` (new)** |
| `.column` | **`showColumnDetail` (new)** |
| `.partition` | `showPartitionDetail` (existing) |
| `.partitionGroup(parent)` | `showPartitionedTableDetail(parent)` (existing) |
| `.schema` | `showNoSelection()` (clear) |
| `.loading` / `nil` (deselect) | no-op (leave panel as-is) |

New Inspector methods, built from the existing detail helpers (`beginDetailSection`, `addDetailField`, `addDetailNote`, `formatRowCount`, `formatByteSize`) so they match the current field/section visual language:

- **`showTableDetail(_ info: TableInfo)`** — header = table name; fields: **Schema** (`info.schemaName`), **Type** (Table / View / Foreign Table from `info.tableType`), **Rows** (`formatRowCount(info.rowCountEstimate)` when present), **Size** (`formatByteSize(info.totalSizeBytes)` when present — omitted for views/foreign tables where it is nil).
- **`showColumnDetail(_ info: ColumnInfo, parentName: String?)`** — header = column name; fields: **Table** (`parentName`, from the selected node's `parent?.tableName`), **Type** (`info.dataType`), **Nullable** (Yes/No from `info.isNullable`), **Primary key** (Yes/No from `info.isPrimaryKey`), **Default** (`info.columnDefault` when present).

Shared-Inspector note: the Inspector is also driven by the results grid (`ContentViewController`). With this change, a schema-tree click takes over the panel (the requested behavior). This is an intentional, user-requested change; no coordination token is added (the pre-existing debounce interaction remains a documented low-severity edge).

## Data Flow

```
User clicks a row → SchemaDataSource.outlineViewSelectionDidChange
  → delegate.schemaDataSourceSelectionDidChange(node)
  → SchemaBrowserVC routes by node.kind → InspectorViewController.show*Detail(...)
     (regular table → showTableDetail; column → showColumnDetail; partition kinds unchanged)
```

## Testing

- Pure logic: none added — this is presentational + view-controller wiring with no extractable pure function (consistent with `pharos-swift-test-harness`: no AppKit unit target).
- Build: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build` must succeed.
- Manual (`/verify`, live app):
  1. Rows visibly roomier (title/subtitle gap, 11pt subtitle, 18pt icon, 44pt rows); column name/type lines no longer cramped.
  2. Partitioned parent shows its strategy pill right-aligned on the title line, clear of the subtitle, with correct selected-state contrast; long names truncate before the pill; non-partitioned tables show no pill.
  3. Inspector: selecting a regular table/view shows Schema/Type/Rows/Size; selecting a column shows Table/Type/Nullable/Primary key/Default; partitioned parent, partition, and partition-group selections still show their existing detail; selecting a schema node clears the panel.

## Open Questions

None blocking. Row height (44) and badge gap are single-constant tweaks if visual polish is wanted after the live pass.
