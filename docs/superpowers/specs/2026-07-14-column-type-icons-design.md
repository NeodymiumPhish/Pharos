# Type-Aware Column Icons — Design

**Date:** 2026-07-14
**Status:** Approved for planning
**Area:** Schema browser column rendering (`SchemaTreeNode.icon`), new pure mapping helper

## Problem

Every column in the Database Navigator shows the same "Aa" glyph regardless of its data type. `SchemaTreeNode.icon` only branches on primary-key status:

```swift
case .column(let info):
    name = info.isPrimaryKey ? "key.fill" : "textformat"
```

`textformat` renders as "Aa" — a generic placeholder used for all non-PK columns; the column's `dataType` is never consulted. So a `boolean`, an `integer`, an `ARRAY`, and a `text` column are visually identical.

## Goal

Make the column icon reflect the column's data type, using **monochrome SF Symbols** (single-tint template glyphs, exactly like the current "Aa" — not emoji, no color). Primary-key columns keep their existing key icon.

## Non-Goals

- No change to primary-key columns (they keep `key.fill` + the yellow tint).
- No change to icon *tint* (columns stay `.secondaryLabelColor`; PK stays `.systemYellow`).
- No new data fetched — `ColumnInfo.dataType` already carries the type string.
- No multicolor/hierarchical symbol rendering — plain template/monochrome only.

## Design

### 1. New pure helper: `ColumnTypeIcon` (`Pharos/Models/ColumnTypeIcon.swift`)

A Foundation-only, unit-testable enum mapping a Postgres `data_type` string (as returned by `information_schema.columns`, e.g. `"integer"`, `"boolean"`, `"ARRAY"`, `"timestamp without time zone"`, `"inet"`) to an SF Symbol name. Never returns nil — unmatched types fall back to `textformat` so nothing renders blank.

```swift
static func symbolName(forDataType dataType: String) -> String
```

Matching is case-insensitive on the trimmed, lowercased type string, order-sensitive where prefixes overlap (check `timestamp` before `time`). Category → symbol:

| Category | Matches (lowercased `data_type`) | SF Symbol |
|---|---|---|
| Text | `text`, `character varying`, `character`, `char`, `"char"`, `name`, `varchar`, `bpchar` | `textformat` |
| Numeric | `smallint`, `integer`, `int`, `int2`, `int4`, `int8`, `bigint`, `decimal`, `numeric`, `real`, `double precision`, `float4`, `float8`, `money` | `number` |
| Boolean | `boolean`, `bool` | `switch.2` |
| Date / Timestamp | starts with `timestamp`, or `date` | `calendar` |
| Time / Interval | starts with `time` (not `timestamp`), or `interval` | `clock` |
| Array | `array`, or ends with `[]` | `curlybraces` |
| JSON | `json`, `jsonb` | `curlybraces.square` |
| Network | `inet`, `cidr`, `macaddr`, `macaddr8` | `network` |
| UUID | `uuid` | `number.square` |
| Binary | `bytea` | `doc` |
| Fallback | anything else (incl. `user-defined`, enums, geometric, etc.) | `textformat` |

All chosen symbols are standard monochrome SF Symbols available on the app's macOS target; they render as single-tint template glyphs via the existing `NSImage(systemSymbolName:)` path (no symbol configuration), adopting `iconView.contentTintColor`.

### 2. Use it in `SchemaTreeNode.icon` (`Pharos/Models/SchemaTreeNode.swift`)

Replace the `.column` arm:

```swift
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : ColumnTypeIcon.symbolName(forDataType: info.dataType)
```

Primary-key columns are unchanged (`key.fill`, yellow tint). Non-PK columns get the type glyph in the existing secondary-label gray. No other code changes — `tintColor` and the cell rendering are untouched.

## Testing

- **Pure logic (test-first):** `PharosTests/ColumnTypeIconTests.swift` + `scripts/test-column-type-icon.sh` (standalone `swiftc`, mirroring `test-partition-ordering.sh`). Compiles `ColumnTypeIcon.swift` + the test + a generated `main.swift` shim. Assert representative mappings and the fallback:
  - `integer` → `number`; `bigint` → `number`; `numeric` → `number`
  - `boolean` → `switch.2`
  - `text` → `textformat`; `character varying` → `textformat`
  - `ARRAY` → `curlybraces`; `_int4`-style `integer[]` (ends `[]`) → `curlybraces`
  - `timestamp without time zone` → `calendar`; `date` → `calendar`
  - `time without time zone` → `clock`; `interval` → `clock`
  - `jsonb` → `curlybraces.square`
  - `inet` → `network`; `cidr` → `network`
  - `uuid` → `number.square`
  - `bytea` → `doc`
  - `USER-DEFINED` → `textformat` (fallback); empty/unknown → `textformat`
- **Build:** `xcodebuild -project Pharos.xcodeproj -scheme Pharos build` succeeds (new file registered — run `xcodegen generate` if the sources glob doesn't pick it up).
- **Manual (`/verify`, live):** expand a table with mixed types; confirm each column shows its type glyph (numeric `#`, boolean toggle, `inet` network glyph, timestamp calendar, ARRAY braces, text "Aa"), all rendered in the same monochrome gray as before; PK columns still show the key; nothing renders blank.

## Open Questions

None. The exact glyph for any category is a one-line change in the mapping if a symbol reads poorly in the live pass.
