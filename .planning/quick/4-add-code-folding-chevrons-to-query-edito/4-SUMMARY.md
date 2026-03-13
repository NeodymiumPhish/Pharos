---
phase: quick-4
plan: 1
subsystem: editor
tags: [code-folding, gutter, ui]
dependency_graph:
  requires: []
  provides: [SQLFoldRegion, SQLFoldingParser, code-folding-ui]
  affects: [LineNumberGutter, SQLTextView, QueryEditorVC]
tech_stack:
  added: []
  patterns: [text-storage-replacement-folding, lex-state-machine-parser]
key_files:
  created:
    - Pharos/Editor/SQLFoldingParser.swift
  modified:
    - Pharos/Editor/SQLTextView.swift
    - Pharos/Editor/LineNumberGutter.swift
    - Pharos/ViewControllers/QueryEditorVC.swift
decisions:
  - Text storage replacement approach for folding (simpler than NSLayoutManager glyph hiding)
  - Region-aware selective unfold on edit (replaced unfold-all-on-edit)
  - Chevrons visible on hover for expanded regions, always visible for collapsed
metrics:
  duration: 253s
  completed: "2026-03-12T15:53:47Z"
---

# Quick Task 4: Add Code Folding Chevrons to Query Editor Summary

SQL code folding with gutter disclosure chevrons using text storage replacement and a line-by-line lex-aware fold region parser.

## What Was Built

### SQLFoldingParser (New)
Line-by-line SQL parser that detects foldable regions by tracking lex state (strings, comments, dollar-quotes) and matching balanced delimiters. Detects CTEs, subqueries, CASE/END, BEGIN/END, and multi-line parenthesized blocks. Regions must span 3+ lines. Nest-aware for inner regions.

### SQLTextView Fold/Unfold
Added `foldRange`/`unfoldRange`/`unfoldAll` methods that replace text ranges with styled placeholders in NSTextStorage. Folded text is preserved in `foldedRanges` array for restoration. Placeholder styled with smaller monospace font, gray foreground, and quaternary background. Offset adjustment handled for multiple simultaneous folds.

### LineNumberGutter Chevrons
Disclosure triangles drawn in the leftmost 14px of the gutter. Down-pointing (expanded) shown on mouse hover, right-pointing (collapsed) always visible. Click handling on the fold column triggers `onToggleFold` callback. Mouse enter/exit tracking for chevron visibility.

### QueryEditorVC Coordination
Wires SQLFoldingParser, LineNumberGutter, and SQLTextView together. Fold regions recalculated on text change and `setSQL`. Collapsed state preserved across re-parses by matching startLine. Text edits selectively unfold only regions whose placeholder overlaps the edit location; distant folds survive. `isUnfoldingAll` flag prevents re-entrant gutter updates.

## Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | SQLFoldingParser + SQLTextView fold/unfold | 3baf7ba | SQLFoldingParser.swift, SQLTextView.swift |
| 2 | Gutter chevrons + QueryEditorVC wiring | eba1ec3 | LineNumberGutter.swift, QueryEditorVC.swift |
| Gap 1 | Region-aware fold preservation on edit | 14270a2 | SQLTextView.swift, QueryEditorVC.swift |
| Gap 2 | CREATE body folding (dollar-quoted) | dd5a024 | SQLFoldingParser.swift |

## Deviations from Plan

None - plan executed exactly as written.

## Decisions Made

1. **Text storage replacement over NSLayoutManager glyph hiding**: The plan offered both approaches and recommended the simpler one. Text storage replacement is more reliable and avoids complex layout manager delegate interactions.
2. **Region-aware selective unfold on edit**: Replaced the initial unfold-all-on-edit strategy with selective unfolding that only affects folds whose placeholder overlaps the edit location. Folds elsewhere in the document survive edits.
3. **Shared chevron/error dot column**: Fold chevrons and error dots share the leftmost gutter space since they rarely co-occur on the same line.

## Verification Gap Fixes

### Gap 1: Fold state cleared on every keystroke (Truth 5 - FIXED)

**Issue:** `textDidChange()` called `textView.unfoldAll()` unconditionally, destroying all folds on any keystroke.

**Fix:** Added `lastEditRange` tracking in `SQLTextView` via `shouldChangeText(in:replacementString:)` override. `QueryEditorVC.textDidChange()` now only unfolds regions whose placeholder range overlaps or is adjacent to the edit location. Folds in distant parts of the document survive text edits.

**Files modified:** `SQLTextView.swift`, `QueryEditorVC.swift`
**Commit:** 14270a2

### Gap 2: CREATE body folding unimplemented (Truth 4 - FIXED)

**Issue:** The `createBody` FoldKind enum case existed but the parser's second pass had no scanning logic for `CREATE` keyword patterns.

**Fix:** Added detection for `CREATE [OR REPLACE] FUNCTION/PROCEDURE ... AS $$ ... $$` in the second pass. Scans forward from `CREATE` to find `AS` followed by a dollar-quote tag, then uses the lex state map to locate the matching closing dollar-quote. Creates `.createBody` fold regions spanning 3+ lines. CREATE TABLE `(...)` patterns were already detected as `.parenBlock`.

**Files modified:** `SQLFoldingParser.swift`
**Commit:** dd5a024
