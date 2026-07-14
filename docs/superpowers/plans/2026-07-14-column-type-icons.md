# Type-Aware Column Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a monochrome SF Symbol that reflects each column's data type in the Database Navigator (numeric `#`, boolean toggle, `inet` network glyph, timestamp calendar, ARRAY braces, text "Aa", …), instead of the current type-blind "Aa" on every column. Primary-key columns keep their key icon.

**Architecture:** A new Foundation-only pure helper `ColumnTypeIcon` maps a Postgres `data_type` string → SF Symbol name (developed test-first via the standalone `swiftc` harness). `SchemaTreeNode.icon` calls it for non-PK columns. No data/model/cell-rendering changes — the icon still renders as a single-tint template glyph through the existing `NSImage(systemSymbolName:)` + `contentTintColor` path.

**Tech Stack:** Swift (Foundation). Standalone `swiftc` test harness (no Xcode test target), mirroring `scripts/test-partition-ordering.sh`.

---

## File Structure

- `Pharos/Models/ColumnTypeIcon.swift` — CREATE: pure `dataType → SF Symbol name` mapping. Testable.
- `PharosTests/ColumnTypeIconTests.swift` + `scripts/test-column-type-icon.sh` — CREATE: standalone test + runner.
- `Pharos/Models/SchemaTreeNode.swift` — MODIFY: one line in the `.column` arm of `icon`.

---

## Task 1: `ColumnTypeIcon` pure mapping (TDD)

**Files:**
- Create: `Pharos/Models/ColumnTypeIcon.swift`
- Create: `PharosTests/ColumnTypeIconTests.swift`
- Create: `scripts/test-column-type-icon.sh`

**Context:** Postgres `information_schema.columns.data_type` returns strings like `"integer"`, `"bigint"`, `"boolean"`, `"text"`, `"character varying"`, `"ARRAY"`, `"timestamp without time zone"`, `"time without time zone"`, `"interval"`, `"jsonb"`, `"inet"`, `"uuid"`, `"bytea"`, `"USER-DEFINED"`. The mapping must be case-insensitive, order-sensitive where prefixes overlap (`timestamp` before `time`), and fall back to `textformat` for anything unmatched. It returns a plain `String` (SF Symbol name) and imports only Foundation, so it compiles standalone with just its test + a generated `main.swift` shim (per `pharos-swift-test-harness`).

- [ ] **Step 1: Write the failing test**

Create `PharosTests/ColumnTypeIconTests.swift`:

```swift
// Standalone test runner for ColumnTypeIcon — no Xcode project involvement.
// Compiled with Pharos/Models/ColumnTypeIcon.swift by scripts/test-column-type-icon.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    func sym(_ t: String) -> String { ColumnTypeIcon.symbolName(forDataType: t) }

    expectEqual(sym("integer"), "number", "integer → number")
    expectEqual(sym("bigint"), "number", "bigint → number")
    expectEqual(sym("numeric"), "number", "numeric → number")
    expectEqual(sym("double precision"), "number", "double precision → number")
    expectEqual(sym("boolean"), "switch.2", "boolean → switch.2")
    expectEqual(sym("text"), "textformat", "text → textformat")
    expectEqual(sym("character varying"), "textformat", "varchar → textformat")
    expectEqual(sym("ARRAY"), "curlybraces", "ARRAY → curlybraces")
    expectEqual(sym("integer[]"), "curlybraces", "type[] → curlybraces")
    expectEqual(sym("timestamp without time zone"), "calendar", "timestamp → calendar")
    expectEqual(sym("date"), "calendar", "date → calendar")
    expectEqual(sym("time without time zone"), "clock", "time → clock")
    expectEqual(sym("interval"), "clock", "interval → clock")
    expectEqual(sym("jsonb"), "curlybraces.square", "jsonb → curlybraces.square")
    expectEqual(sym("inet"), "network", "inet → network")
    expectEqual(sym("cidr"), "network", "cidr → network")
    expectEqual(sym("uuid"), "number.square", "uuid → number.square")
    expectEqual(sym("bytea"), "doc", "bytea → doc")
    expectEqual(sym("USER-DEFINED"), "textformat", "user-defined → fallback")
    expectEqual(sym("  Integer  "), "number", "trims + case-insensitive")
    expectEqual(sym(""), "textformat", "empty → fallback")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

Create `scripts/test-column-type-icon.sh`:

```bash
#!/bin/bash
# Standalone test runner for ColumnTypeIcon — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/column-type-icon-tests \
  Pharos/Models/ColumnTypeIcon.swift \
  PharosTests/ColumnTypeIconTests.swift \
  "$TMPMAIN"
/tmp/column-type-icon-tests
```

Then `chmod +x scripts/test-column-type-icon.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-column-type-icon.sh`
Expected: FAIL — file-not-found / `cannot find 'ColumnTypeIcon' in scope` (implementation doesn't exist yet).

- [ ] **Step 3: Implement `ColumnTypeIcon`**

Create `Pharos/Models/ColumnTypeIcon.swift`:

```swift
import Foundation

/// Maps a PostgreSQL column data-type string (as returned by
/// `information_schema.columns.data_type`) to a monochrome SF Symbol name for the
/// schema browser's column rows. Foundation-only and returns a plain String, so it
/// is unit-testable standalone. Never returns nil — unmatched types fall back to
/// "textformat" (the generic "Aa" glyph) so a column icon never renders blank.
enum ColumnTypeIcon {

    static func symbolName(forDataType dataType: String) -> String {
        let t = dataType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Array first: information_schema reports "ARRAY"; also handle "<type>[]".
        if t == "array" || t.hasSuffix("[]") { return "curlybraces" }

        // Date/time: check the "timestamp" prefix before the generic "time" prefix.
        if t.hasPrefix("timestamp") || t == "date" { return "calendar" }
        if t.hasPrefix("time") || t == "interval" { return "clock" }

        switch t {
        case "boolean", "bool":
            return "switch.2"
        case "json", "jsonb":
            return "curlybraces.square"
        case "inet", "cidr", "macaddr", "macaddr8":
            return "network"
        case "uuid":
            return "number.square"
        case "bytea":
            return "doc"
        case "text", "character varying", "varchar", "character",
             "char", "\"char\"", "name", "bpchar", "citext":
            return "textformat"
        case "smallint", "integer", "int", "int2", "int4", "int8", "bigint",
             "decimal", "numeric", "real", "double precision",
             "float", "float4", "float8", "money":
            return "number"
        default:
            return "textformat"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-column-type-icon.sh`
Expected: `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Pharos/Models/ColumnTypeIcon.swift PharosTests/ColumnTypeIconTests.swift scripts/test-column-type-icon.sh
git commit -m "feat: ColumnTypeIcon — data type → SF Symbol mapping + tests"
```

---

## Task 2: Wire type icons into the column row

**Files:**
- Modify: `Pharos/Models/SchemaTreeNode.swift` (the `.column` arm of `icon`, ~line 131-132)

**Context:** `SchemaTreeNode.icon` currently returns `key.fill` for PK columns and `textformat` for all others. Change only the non-PK branch to use `ColumnTypeIcon`. PK columns and the tint logic are unchanged. New Swift files are not auto-included in the Xcode project's source list, so the project must be regenerated before the app build (same as when `PartitionOrdering.swift`/`PartitionDisplay.swift` were added).

- [ ] **Step 1: Use the mapping in `icon`**

In `Pharos/Models/SchemaTreeNode.swift`, replace the `.column` case in the `icon` computed property:

```swift
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : ColumnTypeIcon.symbolName(forDataType: info.dataType)
```

(Leave the rest of `icon` and all of `tintColor` unchanged — non-PK columns keep `.secondaryLabelColor`, PK columns keep `key.fill` + `.systemYellow`.)

- [ ] **Step 2: Regenerate the Xcode project**

The new `Pharos/Models/ColumnTypeIcon.swift` must be registered in the app target.

Run: `xcodegen generate`
Expected: `Created project at Pharos.xcodeproj`.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. (If it fails with `cannot find 'ColumnTypeIcon' in scope`, the regen in Step 2 didn't pick up the file — confirm the file is under `Pharos/Models/` and re-run `xcodegen generate`.)

- [ ] **Step 4: Commit**

```bash
git add Pharos/Models/SchemaTreeNode.swift Pharos.xcodeproj/project.pbxproj
git commit -m "feat: type-aware column icons in the schema navigator"
```

- [ ] **Step 5: Manual verify (`/verify`, live app)**

Rebuild in Xcode. Expand a table with mixed column types (e.g. the `x509`/`analyzer` tables) and confirm: numeric columns show `#`, `boolean` shows a toggle, `inet` columns (`orig_h`/`resp_h`) show the network glyph, `timestamp` columns show a calendar, an `ARRAY` column shows braces, `text` columns still show "Aa" — all rendered in the same monochrome gray as before (no color, not emoji); primary-key columns still show the key icon in yellow; no column renders blank.

---

## Self-Review Notes

- **Spec coverage:** the mapping table (spec §1) → Task 1's `symbolName` + tests; the `SchemaTreeNode.icon` wire-in (spec §2) → Task 2 Step 1; PK-unchanged + tint-unchanged → explicitly preserved in Task 2 Step 1; new-file registration → Task 2 Step 2 (`xcodegen generate`).
- **Placeholder scan:** none — full test and implementation code inline.
- **Type consistency:** `ColumnTypeIcon.symbolName(forDataType:) -> String` is defined in Task 1 and called with that exact signature in Task 2. Returns a symbol-name String used directly as `name` for `NSImage(systemSymbolName:)`.
- **No AppKit in the helper:** `ColumnTypeIcon` imports only Foundation (returns a String), so the standalone `swiftc` test compiles it without AppKit — consistent with `pharos-swift-test-harness`.
