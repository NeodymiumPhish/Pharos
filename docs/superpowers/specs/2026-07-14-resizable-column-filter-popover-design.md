# Resizable / Auto-Sizing Column Filter Popover

**Date:** 2026-07-14
**Status:** Approved (design)

## Problem

The column filter popover (`ColumnFilterPopoverVC`) opens at a fixed width. Every
arranged subview is pinned to `innerWidth = 236` and `recalculateSize()` floors
the popover width at 260 (`ColumnFilterPopoverVC.swift:171,477`). The value
checklist (`FilterValueListView`) renders each distinct value as an
`NSButton(checkboxWithTitle:)` title with `.byTruncatingTail`
(`FilterValueListView.swift`).

When a column holds long values — e.g. the `query` column of a Zeek `dns` table
(`12.227.233.238.1782722400.main...`, `000653ab5eedfa27.2aea.12-2000...`) — the
rows all truncate to roughly the same prefix, so the user can't tell candidate
values apart to decide what to include/exclude. The only recourse today is
hovering each row for its tooltip.

## Goal

Let the popover fit long values:

1. **Auto-size on open** — width sized to fit the loaded distinct values, clamped
   between a minimum and a maximum.
2. **Drag-to-resize** — a corner grip lets the user widen the popover *and* grow
   the value list taller (to see more rows), within the same clamps.
3. Both width and the value-list height are adjustable; **height is draggable,
   not just width.**

The maximum is **relative to the window** (a fraction of the results pane), not a
fixed pixel value.

## Non-Goals

- No change to the filtering logic, the distinct-value query, or the
  Advanced-text-filter operators.
- No wrapping of long values — rows stay single-line `.byTruncatingTail` with the
  existing full-value tooltip. A wider/taller popover just makes truncation far
  less likely to bite.
- No persistence of the chosen size across popover opens (each open re-auto-sizes;
  YAGNI unless asked).

## Sizing Model

All sizing is expressed against a **reference size** = the results table's
enclosing scroll-view bounds (the results pane). If that is unavailable, fall back
to the popover view's `window?.contentView` bounds, then to a hard default
(`800 × 600`). Getter lives on the VC.

Constants:

- `minWidth = 260` (current floor).
- `maxWidth = 0.6 × referenceWidth`, never below `minWidth`.
- `minListHeight = 120` (roughly 5 rows at `rowHeight 20 + spacing 2`).
- `defaultListHeight = 180` (current fixed value).
- `maxListHeight = 0.6 × referenceHeight`, never below `minListHeight`.

Width applies to the whole popover via `preferredContentSize.width`. Height is
applied to the value list only (`FilterValueListView`); the popover's overall
height stays content-driven through `recalculateSize()`, which sums the list
height with the header/search/advanced/buttons.

## Components

### 1. `ColumnFilterPopoverVC.swift` (edits)

**Make width dynamic.** Change the main `stackView.alignment` from `.leading` to
`.fill` (it is already pinned leading/trailing to the container with 12pt insets,
`:109-114`). Remove the fixed `widthAnchor == innerWidth` constraints currently
applied to `searchField`, `valueList`, `operatorPopup`, `advancedContainer`, and
`buttonRow` (`:179,182,189,191,193`). With `.fill`, these stretch to the stack
width, which is driven by `preferredContentSize.width`. The small intentional
fixed-width fields inside rows (`intervalDays` etc. at width 40) stay as-is.

This also removes the constraint-accumulation issue where `updateValueArea`
re-activates `value2Field` / `tokenField` / `timePicker` width constraints on
reused fields without deactivating the prior ones (`:461` and siblings): those
`innerWidth` width constraints are deleted rather than re-added.

**Auto-size on open.** Add `autoSizeWidth()`:
- Measure each loaded distinct value's rendered width with
  `(value as NSString).size(withAttributes: [.font: systemFont(ofSize: 12)])`.
  Take the widest.
- `contentWidth = widest + checkboxChrome (≈ 24) + scrollerAllowance (≈ 20) +
  stack insets (24)`.
- `width = min(max(contentWidth, minWidth), maxWidth)`.
- Set as the initial width used by `recalculateSize()`.
- The per-value measuring helper lives on `FilterValueListView` (it owns the
  values and the font); the VC calls it and applies the clamp.

**`recalculateSize()` (edit `:473-479`).** Track a stored width:
```
private var currentWidth: CGFloat = 260   // set by autoSizeWidth / drag
private var userDidResize = false
```
Use `currentWidth` for `preferredContentSize.width` instead of
`max(260, fitting.width)`. Height still comes from `fitting.height` (which now
reflects the possibly-taller list). Auto-size runs once when values load; if
`userDidResize` is true, later recalcs (search typing, advanced toggle) keep the
user's width — auto-size never overrides a manual choice.

**Drag-to-resize.** Add a `ResizeGripView` (see below) pinned to the container's
bottom-right corner, above the stack in z-order. Its drag callback delivers a
cumulative delta from drag start:
- `currentWidth = clamp(startWidth + dx, minWidth, maxWidth)`.
- `listHeight = clamp(startListHeight + dy, minListHeight, maxListHeight)` →
  pushed to `valueList.setListHeight(_:)`.
- Set `userDidResize = true`, then `recalculateSize()`.
- During an active drag, set `hostPopover?.animates = false` to avoid per-frame
  reposition animation; restore `true` on drag end.

**Popover reference.** Add `weak var hostPopover: NSPopover?`, set by the
presenter after creation (see edit 3). Used only to toggle `animates` during drag.

### 2. `ResizeGripView.swift` (new, same folder)

A small (`~14 × 14`) `NSView` drawn as the standard diagonal-lines resize glyph
(two or three short strokes) using `secondaryLabelColor`. Responsibilities:

- The diagonal-lines glyph is the primary visual affordance. AppKit exposes no
  public diagonal-resize cursor, so do **not** override the cursor — leave the
  default arrow. (An `NSCursor(image:hotSpot:)` custom cursor is a possible later
  polish, out of scope here.)
- On `mouseDown`, record the start point. On `mouseDragged`, compute
  `dx = event.locationInWindow.x - start.x`,
  `dy = start.y - event.locationInWindow.y` (down-drag grows height) and invoke
  `onDrag?(dx, dy)`. On `mouseUp`, invoke `onDragEnd?()`.
- Knows nothing about filters — pure gesture-to-delta reporter via closures
  (`onDrag: ((CGFloat, CGFloat) -> Void)?`, `onDragEnd: (() -> Void)?`).

### 3. `ResultsGridVC+Delegates.swift` (edit)

In `headerView(_:didClickFilterForColumn:at:)` (`:135-149`), after
`popover.contentViewController = popoverVC` and before `popover.show(...)`, set
`popoverVC.hostPopover = popover`. No other change; presentation is unchanged.

### 4. `FilterValueListView.swift` (edits)

- Replace the hard `heightAnchor == 180` constraint (`:55`) with a stored
  `heightConstraint` (constant `defaultListHeight = 180`) and expose
  `func setListHeight(_ h: CGFloat)` that updates the constant. Guard callers so
  the VC's clamp is the source of truth.
- Add `func maxValueWidth(font: NSFont) -> CGFloat` returning the widest rendered
  width across `allValues` (post `setValues`, pre-search — measure the full set so
  auto-size doesn't shrink when the user searches). Returns 0 for an empty list.

## Data Flow

1. User clicks the column's filter glyph → `ResultsGridVC+Delegates` builds
   `ColumnFilterPopoverVC`, sets `hostPopover`, shows the popover.
2. On load, the VC calls `autoSizeWidth()` → measures values via
   `FilterValueListView.maxValueWidth(font:)`, clamps against `maxWidth`
   (0.6 × results pane width), stores `currentWidth`, calls `recalculateSize()`.
3. Popover appears already sized to fit its values (up to the cap).
4. User drags the corner grip → `ResizeGripView` reports cumulative `(dx, dy)` →
   VC clamps width and list height, marks `userDidResize`, recalculates;
   `hostPopover.animates` is off for the duration.
5. Typing in Search / toggling Advanced recalculates height as today but preserves
   `currentWidth` (auto or user-chosen).

## Error / Edge Handling

- **Empty distinct-value list:** `maxValueWidth` returns 0 → width clamps to
  `minWidth = 260`; grip still works up to `maxWidth`.
- **Tiny / unavailable reference size:** fall back chain
  (results pane → window content → 800×600); `maxWidth`/`maxListHeight` never fall
  below their minimums, so the popover is always usable.
- **Very long single outlier value:** width is capped at `maxWidth`; that row
  truncates with tooltip — acceptable and expected.
- **Drag past bounds:** clamps hold width in `[minWidth, maxWidth]` and list height
  in `[minListHeight, maxListHeight]`; the popover can't grow off-screen.
- **Advanced section expanded while narrow:** the calendar/operator controls now
  stretch to the popover width via `.fill`; no fixed 236 clipping.
- **Transient dismissal mid-drag:** `.transient` popover closing during a drag just
  ends the interaction; `onDragEnd` restoring `animates = true` is harmless on a
  dismissed popover (guard with `hostPopover?`).

## Testing

- **Manual (primary):** open the filter on a Zeek `dns.query` column. Confirm the
  popover opens wider than today, fitting most values without hovering; drag the
  corner grip to widen further (up to ~60% of the results pane) and to lengthen the
  list; confirm it won't exceed the cap or grow off-screen.
- **Manual:** short-value column (e.g. `qclass`) still opens near the 260 minimum,
  not needlessly wide.
- **Manual:** after a manual resize, type in Search and toggle Advanced — width
  stays put, height recomputes correctly, Advanced controls fill the width.
- **Regression:** Clear/Apply, Select-All tri-state, blanks sentinel, tooltips, and
  existing-filter restoration behave exactly as before.
- **Harness (optional):** a standalone `swiftc` AppKit harness can exercise
  `FilterValueListView.maxValueWidth(font:)` and `ResizeGripView`'s delta reporting
  headlessly, per the project's test-harness notes.
