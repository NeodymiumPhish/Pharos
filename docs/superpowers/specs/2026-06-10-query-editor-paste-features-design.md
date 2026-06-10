# Query Editor Paste Features — Design

Date: 2026-06-10
Status: Approved pending final spec review

Two opinionated query-editor features:

1. **Context-aware auto-close** — don't auto-insert a closing bracket/quote when there is text immediately to the right of the cursor.
2. **"Format as SQL list"** — after pasting a multi-line value list, surface a highlighted toolbar button (plus a selection-based context-menu command) that quotes and comma-separates the values.

---

## Feature 1: Context-Aware Auto-Close

### Behavior

In `SQLTextView.insertText(_:replacementRange:)` (currently `Pharos/Editor/SQLTextView.swift:334-348`), auto-close for `(`, `[`, and `'` fires **only** when the character following the insertion point is one of:

- end of document
- whitespace or newline
- a closing delimiter: `)`, `]`, `,`, `;`

Otherwise the typed character is inserted alone (no companion close character).

### Details

- **Selection handling:** when the selection is non-empty, typing an opener *wraps* the selection (`(` around `text` yields `(text)`), with the caret placed after the closing character so typing can continue. The follower-character rule applies only to empty selections.
- The existing apostrophe heuristic (no auto-close for `'` after an alphanumeric) is kept and runs first.
- Skip-over behavior (typing `)` when `)` is next) and pair-deleting backspace are unchanged.

---

## Feature 2: Format as SQL List

### Overview

Pasting always inserts the clipboard content as-is (existing indent-aware paste preserved). If the pasted content *looks like a bare value list*, a highlighted **"Format as SQL list"** button appears in the editor pane toolbar (right of the schema popup — the spot marked in the user's screenshot). Clicking it (or pressing **Tab** while it is visible) rewrites the just-pasted range into a SQL-ready list. The same transform is available any time via a **right-click context-menu item** acting on the current selection — this is the escape hatch that makes detection misses harmless.

### Components

1. **`SQLListFormatter`** — new file `Pharos/Editor/SQLListFormatter.swift`. Pure, stateless functions; no UI or AppKit text dependencies:
   - `static func looksLikeBareList(_ text: String) -> Bool` — detection heuristic.
   - `static func sqlize(_ text: String) -> String` — the transform.

2. **`SQLTextView`** changes:
   - `paste(_:)` (currently line 355): after inserting, record the pasted `NSRange`; if `looksLikeBareList` passes, invoke a new callback `onListPasteDetected: (() -> Void)?`. (The pane only needs a signal, not the range.)
   - Track offer state; any subsequent text edit or selection move invokes `onListPasteOfferInvalidated: (() -> Void)?` and clears the state. (Focus loss deliberately does NOT invalidate: it would race with clicking the toolbar button under Full Keyboard Access, and the range cannot go stale because every edit invalidates.)
   - `keyDown`: while an offer is active, **Tab** applies the transform (and is consumed); **Esc** dismisses the offer. Shift+Tab is excluded — it keeps its dedent meaning.
   - `menu(for:)` override: insert at the top of the menu the "Format as SQL list" item when the selection is non-empty; it applies `sqlize` to the selected text.
   - `func applyPendingSQLize()` — applies the transform to the recorded pasted range via `insertText(_:replacementRange:)` so it lands on the undo stack as its own step (⌘Z restores the raw paste; ⌘Z again removes the paste).

3. **`EditorPaneVC`** changes:
   - New `formatListButton` (`NSButton`, title "Format as SQL list") appended to `toolbarStack` after `schemaPopup`. Hidden by default. When shown, styled to stand out: accent tint, bordered/highlighted, tooltip "Format pasted values as a quoted, comma-separated SQL list (Tab)".
   - Wires the text view callbacks (via `QueryEditorVC`) to show/hide the button. Button click calls `applyPendingSQLize()`.
   - Button hides after applying, on offer invalidation, and on editor-tab switches (`setSQL` explicitly invalidates). A pending offer in one pane stays visible while working in another pane — it remains valid for its own text view. State is per-pane (each `EditorPaneVC` owns its own toolbar and button).

### Detection heuristic (`looksLikeBareList`)

Offer **only when all** of these hold:

- 2+ non-empty lines, total ≤ 5,000 lines, no line longer than 1,000 characters.
- ≥ 80% of non-empty lines are a single token (no internal whitespace after trimming) — tolerates a stray header line.
- No strongly-SQL keywords anywhere, matched case-insensitively on word boundaries: `SELECT, FROM, WHERE, INSERT, UPDATE, DELETE, JOIN, CREATE, ALTER, DROP, UNION, HAVING, VALUES, LIMIT`. Deliberately excludes short ambiguous words (`IN`, `OR`, `ON`, `AS`, `AND`, `BY`) that can legitimately appear as values — e.g., a list of US state codes containing `OR` and `IN`. Real SQL queries have multi-token lines and fail the single-token rule anyway.
- Not already a formatted SQL list: skip if every non-empty line is a quoted token (`'…'` or `"…"`) with optional trailing comma **and** at least one trailing comma is present.

False positives cost one keystroke (the button ignores itself away); false negatives are covered by the context-menu command, so the heuristic stays conservative and simple.

### Transform (`sqlize`)

1. Split into lines; trim each; drop empty lines.
2. Normalize each token: strip one trailing comma, then strip one layer of wrapping single or double quotes — handles input that is already partially quoted/comma'd without double-quoting.
3. Escape embedded single quotes (`'` → `''`).
4. Type inference across the whole list: if **every** token matches integer/decimal (`^-?\d+(\.\d+)?$`), or every token is `true`/`false` (case-insensitive), or every token is `NULL` — emit unquoted. Any mix or any other token → quote **all** tokens. (Quoted numerics are valid in Postgres `IN` lists; unquoted strings are a syntax error, so bias toward quoting.)
5. **Output preserves the list view**: one value per line, in input order, comma after every value except the last. Each output line keeps the leading indentation of its source line (which the indent-aware paste already normalized). Empty input lines are dropped. No wrapping parentheses.

Example — pasting:

```
10.0.0.1
10.0.0.2
10.0.0.3
```

then accepting yields:

```
'10.0.0.1',
'10.0.0.2',
'10.0.0.3'
```

### Context-menu command

"Format as SQL list" in the editor's right-click menu, enabled when the selection is non-empty. Runs the same `sqlize` on the selection (no detection gate — explicit user intent). The selection is extended to whole-line boundaries before transforming so partial-line selections behave predictably.

### Error handling / edge cases

- Values with internal spaces (`New York`): won't trigger the auto-offer, but the manual command quotes each line as one value.
- Apostrophes (`O'Brien`) → `O''Brien`.
- Trailing comma: impossible by construction (commas are joined between values, never appended).
- Mixed already-quoted and bare tokens: normalization strips first, so output is uniform.
- The offer never auto-applies; pasting is always verbatim first.

### Testing

- `SQLListFormatter` is a pure function pair; if the project has no test target, verify via a temporary CLI harness or manual matrix covering: bare strings, integers, decimals, booleans, NULLs, mixed types, pre-quoted input, trailing commas, apostrophes, full SQL query paste (no offer), already-formatted list (no offer), single-line paste (no offer).
- Manual verification in-app: paste flows, Tab accept, Esc dismiss, button click, undo behavior (two steps), context-menu command, per-pane button independence, offer invalidation on edit/tab-switch.
