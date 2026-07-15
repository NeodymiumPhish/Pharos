# Query Variables — Design Spec

Date: 2026-07-15
Status: Approved design, pending implementation plan

## Summary

Add per-tab **query variables** to Pharos. A user defines named variables (name,
value, type) in a collapsible panel docked to the right of the query editor, and
references them in the SQL using `{{name}}` tokens. The editor always shows the
token form (`{{name}}`), but everything that leaves the editor toward Postgres or
the clipboard — query execution, validation, "Copy SQL", and SQL export — sees the
**rendered** SQL with tokens replaced by their values. A toolbar toggle (SF Symbol)
shows/hides the panel.

Substitution is done entirely client-side in Swift before the FFI boundary. There
is no Postgres bind-parameter mechanism in `pharos-core`; the SQL crosses the FFI
as a fully-formed string, so we render the string first.

## Decisions (resolved during brainstorming)

- **Reference syntax:** `{{name}}` (Handlebars/Jinja-style paired delimiter). Chosen
  over a bare sigil (`@name`, `:name`, `$name`) because a paired delimiter is
  self-bounding and cannot be accidentally formed by legitimate SQL or string data
  (emails like `admin@example.com`, operators `@>`/`@@`, `::` casts, `$1` params,
  `$tag$` dollar-quoting all pass through untouched). This removes the need for
  fragile lookbehind heuristics and lets us confidently flag undefined tokens.
- **Substitution style:** per-variable type selector defaulting to **Literal** (raw,
  verbatim). Non-literal types format/escape on substitution.
- **Type set:** `Literal`, `Text`, `Number`, `Bool`, `Null`.
- **Scope:** per-tab. Variables live on `QueryTab` in memory during a session.
- **Persistence:** rides on Saved Queries — no new workspace/session-persistence
  system. Saving a query persists its variables; reopening restores them. (Tabs
  themselves are not persisted today; building session persistence is explicitly
  out of scope.)
- **Editor highlighting:** `{{…}}` tokens are highlighted; undefined tokens are
  flagged distinctly.

## Data model (`Pharos/Models/`)

```swift
enum VariableType: String, Codable {
    case literal, text, number, bool, null
}

struct QueryVariable: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String            // stored WITHOUT the surrounding braces, e.g. "target_ip"
    var value: String
    var type: VariableType = .literal
}
```

`QueryTab` (`Pharos/Models/QueryTab.swift`) gains:

```swift
var variables: [QueryVariable] = []
var variablesPanelVisible: Bool = false   // panel visibility remembered per tab
```

`QueryVariable` is `Codable` for (a) JSON persistence with saved queries and (b) any
JSON transit needed. Mutations flow through `AppStateManager.updateTab(id:_:)` like
existing per-tab fields (`sql`, `connectionId`, `schemaName`).

## Substitution engine — `VariableSubstitutor` (pure Swift, no Rust changes)

New type in `Pharos/Core/` (or `Pharos/Models/`), with a single pure entry point —
the one source of truth for turning token-form SQL into rendered SQL:

```swift
enum VariableSubstitutor {
    struct Result {
        var sql: String            // rendered SQL (what is sent to Postgres)
        var unresolved: [String]   // token names present in SQL but not defined
        var invalid: [(name: String, reason: String)]  // e.g. Number type, non-numeric value
    }
    static func render(_ sql: String, with variables: [QueryVariable]) -> Result
}
```

### Token matching

- Regex: `\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}` — a `{{`, optional inner
  whitespace, an identifier, optional whitespace, `}}`. The captured identifier is
  the variable name.
- Any token whose name is **not** defined is left verbatim in the output and its
  name added to `unresolved`.
- "Only substitute defined names" is retained as a safety net (not load-bearing,
  since the delimiter is already collision-proof).

### Formatting by type

| Type      | Rendering of value `v`                                              |
|-----------|--------------------------------------------------------------------|
| `literal` | `v` verbatim                                                       |
| `text`    | `'` + `v` with every `'` doubled to `''` + `'`  (SQL-safe literal) |
| `number`  | `v` verbatim; if `v` is not a valid numeric literal → `invalid`    |
| `bool`    | normalized to `true` / `false` (accepts true/false/1/0/yes/no, case-insensitive); otherwise `invalid` |
| `null`    | `NULL` (the value field is ignored)                                |

"**Rendered SQL**" is defined precisely as *the exact string sent to Postgres*.

## Where substitution is applied

| Site                         | File:line (approx)                                   | Behavior |
|------------------------------|------------------------------------------------------|----------|
| Execution (choke point)      | `ContentViewController.performQuery` ~1122           | Render the SQL before calling `PharosCore.executeQuery` / `executeStatement` (~1186/1220). Because the rendered string is what runs, result tabs and query history naturally capture rendered SQL. |
| Validation                   | `QueryEditorVC.validateSQL` ~546                     | Render before calling `PharosCore.validateSQL` so tokens don't register as syntax errors. |
| Editor export/copy as SQL    | `ContentViewController.menuExportEditorAsSQL` ~1972; Save-dropdown | Render using the active tab's variables before writing/copying. |
| Saved-query copy/export      | `SavedQueriesVC` ~382 (Copy SQL), ~400/499 (SQL export) | Render using that saved query's stored variables. |
| Pre-flight guard (execution) | `performQuery`, before dispatch                       | If `unresolved` or `invalid` is non-empty: block execution, surface an inline error naming the offending token(s), auto-open the variables panel, and highlight the token in the editor. |

The editor text itself **always** keeps token form. `QueryTab.sql` remains the
token-form source of truth. Segment-based execution is respected: rendering happens
on the SQL string chosen at the `performQuery` boundary (segment slice or full text),
not before segment selection.

## Persistence (rides on Saved Queries)

- Session tabs hold variables in memory on `QueryTab`.
- On **Save Query**, the tab's `variables` serialize to JSON and persist alongside
  `SavedQuery.sql`. Requires:
  - a new `variables` column (TEXT, JSON) on the `saved_queries` SQLite table
    (`pharos-core/src/db/sqlite.rs`, with an `ALTER TABLE ... ADD COLUMN` migration
    guarded like the existing connections migration);
  - the `SavedQuery` model carrying the JSON string on both the Rust side
    (`pharos-core/src/models/`) and the Swift side (`Pharos/Models/`);
  - save/load paths in `pharos-core/src/commands/saved_query.rs` and the FFI wrapper
    (`pharos-core/src/ffi/saved_queries.rs`) round-tripping the field.
- Reopening a saved query restores its variables into the tab.
- No new workspace/session-persistence system is introduced.

## UI — right-docked panel + toolbar toggle (all coordinated by `EditorPaneVC`)

### Toolbar toggle
- An SF Symbol recessed button using `curlybraces`, added in
  `EditorPaneVC.setupEditorToolbar()`.
- **Right-aligned:** added as a subview of `editorToolbar` and constrained
  `trailingAnchor == editorToolbar.trailingAnchor - 8`, `centerYAnchor ==
  editorToolbar.centerYAnchor`. (The existing controls stack is leading-anchored
  only, so the right side of the bar is free.)
- Toggling flips `tab.variablesPanelVisible` (via `AppStateManager.updateTab`) and
  animates the panel in/out.
- Optional: a small count badge when the active tab has ≥1 variable.

### Variables panel — `QueryVariablesPanelVC` (new, `Pharos/ViewControllers/`)
- Docked to the right of the editor, below the toolbar, matching editor height.
- Reuses `EditorPaneVC`'s existing **frame-based** layout: in
  `EditorPaneVC.viewDidLayout`, when `variablesPanelVisible`, reserve a right strip
  of the current panel width and reduce the editor's frame width accordingly;
  animate width on toggle.
- **Drag-resizable:** a thin divider view (~4 pt) on the panel's left edge acts as a
  drag handle. It sets `NSCursor.resizeLeftRight` on hover (via a tracking area /
  `resetCursorRects`) and tracks mouse drag to update the panel width, clamped to
  `[180, 600]` pt; `EditorPaneVC.viewDidLayout` reads the width and re-lays out the
  editor + panel live during the drag. (A lightweight divider is used rather than
  converting the pane to an `NSSplitView`, keeping the existing frame-based layout
  intact.)
- **Width persistence:** the panel width is app-wide and stored in `UserDefaults`
  (default 260 pt, clamped to the same range on read) — Swift-only, no FFI/Rust
  change. (Panel *visibility* remains per-tab on `QueryTab`; only the width is
  shared and persisted this way.)
- Contents: a header row ("Variables" label + "add" button) above a scrollable
  vertical `NSStackView` of variable rows. Each row:
  - `{{`name`}}` name field (identifier only; braces shown as non-editable affordance),
  - value field,
  - type popup (`Literal` / `Text` / `Number` / `Bool` / `Null`),
  - delete button.
- All edits write back to the active tab's `variables` through
  `AppStateManager.updateTab`.
- On tab switch, the panel rebinds to the active tab's `variables` and its
  `variablesPanelVisible`.

### Editor highlighting (`SQLTextView` / existing highlight pass)
- The highlight pass receives the active tab's defined variable names.
- Defined `{{name}}` tokens render in an accent color.
- Undefined `{{name}}` tokens (they match the token regex but have no definition)
  render with a distinct warning treatment (e.g. dashed/error underline) — this is
  reliable because the delimiter pair is unambiguous.

## Error handling

- **Undefined token at run time:** blocked pre-flight (see guard row above), panel
  auto-opens, token highlighted, inline message names it.
- **Invalid typed value** (e.g. `Number` with `"abc"`): same treatment, message
  states the type/value problem.
- **Empty value with `Literal`/`Text`:** allowed (renders empty string / `''`);
  not an error.

## Testing & verification

- **Unit:** `VariableSubstitutor.render` via a standalone `swiftc` script (this repo
  has no Xcode test target — see project test-harness notes). Cover: each type's
  formatting, `'`→`''` escaping, numeric/bool validation, unresolved collection,
  optional inner whitespace, and the collision cases that motivated `{{…}}`
  (`admin@example.com`, `@>`, `::cast`, `$1`, `$tag$`) confirming they are NOT
  altered.
- **Manual (run skill):** panel add/edit/delete + type popup; toggle show/hide and
  per-tab memory; editor highlighting of defined vs undefined tokens; execute a
  query with variables and confirm the rendered SQL runs; confirm Copy SQL / export
  show rendered SQL; save a query and reopen to confirm variables restore.

## Out of scope (YAGNI)

- List/Array variable type (for `IN (...)`).
- Click-to-add a variable directly from an undefined token in the editor.
- Whole-tab/session/workspace persistence.
- Postgres server-side bind parameters.
```

## Affected files (reference)

- Swift models: `Pharos/Models/QueryTab.swift`, new `QueryVariable`/`VariableType`,
  `Pharos/Models/SavedQuery` model.
- Swift core: new `VariableSubstitutor`, `Pharos/Core/AppStateManager.swift`.
- Swift VCs/views: `Pharos/ViewControllers/EditorPaneVC.swift`,
  `Pharos/ViewControllers/QueryEditorVC.swift`,
  `Pharos/ViewControllers/ContentViewController.swift`,
  `Pharos/ViewControllers/SavedQueriesVC.swift`, new `QueryVariablesPanelVC.swift`,
  `Pharos/Editor/SQLTextView.swift` (highlighting).
- Rust: `pharos-core/src/db/sqlite.rs` (migration), `pharos-core/src/models/`
  (SavedQuery), `pharos-core/src/commands/saved_query.rs`,
  `pharos-core/src/ffi/saved_queries.rs`.
- Project: `project.yml` / `xcodegen generate` for the new Swift file.
