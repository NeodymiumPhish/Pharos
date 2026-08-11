// Standalone test runner for the row tag models and the result row identity.
// Not part of the app target — compiled together with the implementation by
// scripts/test-row-tag-models.sh.
//
// WHY THIS SUITE EXISTS: two casing conventions meet in these files.
//
//   * QueryResult / ColumnDef / KeySet / RowIdentity mirror Rust structs that
//     carry NO `rename_all`, so their JSON keys are snake_case and the Swift
//     structs need explicit CodingKeys.
//   * TagLabel / RowTag / UpsertRowTag / ... mirror Rust structs that carry
//     `rename_all = "camelCase"`, so their keys are already camelCase and the
//     Swift structs must carry NO CodingKeys.
//   * QueryHistoryResultData mixes both: the outer key is `rowIdentity`, while
//     the identity block nested inside it keeps snake_case.
//
// JSONDecoder.pharos applies NO key strategy (Pharos/Core/PharosCore.swift),
// so a casing mismatch throws at RUN time and never at build time. Only a
// decode test like this one can catch it. Every JSON literal below for the
// snake_case group is ground truth, printed from the real Rust types.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectNil<T>(_ actual: T?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name) — expected nil, got \(String(describing: actual))")
    }
}

/// Decodes or records the thrown error as a failure. Every test here is about
/// whether a real payload decodes at all, so the error text is what a failure
/// needs to show — `try?` would hide the key name that did not match.
func decode<T: Decodable>(_ type: T.Type, _ json: String, _ name: String) -> T? {
    do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        failures += 1
        print("FAIL \(name) — decode threw: \(error)")
        return nil
    }
}

func runTests() {

    // MARK: 1 — a RowTag decodes from camelCase

    // The tag models carry `rename_all = "camelCase"` in Rust, so the keys below
    // are exactly what Rust writes. `identityValues` holds a null (a NULL column
    // value), and `keys` holds two entries (a strong tag satisfying both a pk and
    // a unique index).
    let rowTagJSON = """
    {"id":"t1","connectionId":"c1","labelId":"l1","note":"check this",\
    "primaryKind":"pk","tableKey":"oid:16543","tableDisplay":"public.users",\
    "identityColumns":["id","email"],"identityValues":["42",null],\
    "keys":[{"identityKind":"pk","identityValue":"V1:42"},\
    {"identityKind":"unique","identityValue":"V1:a@b.co"}],\
    "createdAt":"2026-08-11T00:00:00Z","updatedAt":"2026-08-11T00:00:01Z"}
    """
    if let tag = decode(RowTag.self, rowTagJSON, "RowTag decodes from camelCase") {
        print("PASS RowTag decodes from camelCase")
        expectEqual(tag.id, "t1", "RowTag.id")
        expectEqual(tag.connectionId, "c1", "RowTag.connectionId from key connectionId")
        expectEqual(tag.labelId, "l1", "RowTag.labelId from key labelId")
        expectEqual(tag.note, "check this", "RowTag.note")
        expectEqual(tag.primaryKind, "pk", "RowTag.primaryKind from key primaryKind")
        expectEqual(tag.tableKey, "oid:16543", "RowTag.tableKey from key tableKey")
        expectEqual(tag.tableDisplay, "public.users", "RowTag.tableDisplay from key tableDisplay")
        expectEqual(tag.identityColumns, ["id", "email"], "RowTag.identityColumns from key identityColumns")
        // A null inside identityValues must survive as a nil element, not collapse
        // the array or become the string "null" — it is how a NULL key value is
        // carried, and the popover has to tell it apart from an empty string.
        expectEqual(tag.identityValues.count, 2, "RowTag.identityValues keeps both elements")
        expectEqual(tag.identityValues.first ?? nil, "42", "RowTag.identityValues[0]")
        expectTrue(tag.identityValues.count == 2 && tag.identityValues[1] == nil,
                   "RowTag.identityValues[1] is nil for a JSON null")
        expectEqual(tag.keys.count, 2, "RowTag.keys keeps both entries")
        expectEqual(tag.keys.first, RowTagKey(identityKind: "pk", identityValue: "V1:42"),
                    "RowTag.keys[0] from keys identityKind/identityValue")
        expectEqual(tag.keys.last, RowTagKey(identityKind: "unique", identityValue: "V1:a@b.co"),
                    "RowTag.keys[1] from keys identityKind/identityValue")
        expectEqual(tag.createdAt, "2026-08-11T00:00:00Z", "RowTag.createdAt from key createdAt")
        expectEqual(tag.updatedAt, "2026-08-11T00:00:01Z", "RowTag.updatedAt from key updatedAt")
    }

    // A label comes over the same way — colorIndex/sortOrder, not color_index.
    let labelJSON = """
    {"id":"l1","name":"Bad data","colorIndex":2,"sortOrder":0,"createdAt":"2026-08-11T00:00:00Z"}
    """
    if let label = decode(TagLabel.self, labelJSON, "TagLabel decodes from camelCase") {
        print("PASS TagLabel decodes from camelCase")
        expectEqual(label.colorIndex, 2, "TagLabel.colorIndex from key colorIndex")
        expectEqual(label.sortOrder, 0, "TagLabel.sortOrder from key sortOrder")
    }

    // MARK: 2 — a QueryResult decodes from snake_case

    // Ground truth, printed from the real Rust types. Note `data_type`,
    // `relation_oid`, `row_identity`, `table_key`, `key_columns` — all
    // snake_case, because those Rust structs carry no `rename_all`.
    let resultJSON = """
    {"columns":[{"name":"id","data_type":"INT4","relation_oid":609999,"relation_attno":1}],\
    "rows":[["1"],["2"]],"row_count":2,"execution_time_ms":3,"has_more":false,\
    "history_entry_id":"h1",\
    "row_identity":{"table_key":"oid:609999","table_display":"tagtest.users",\
    "table_keys":["oid:609999"],\
    "candidates":[{"kind":"pk","key_columns":["id"],"keys":["V1:1","V1:2"]}]}}
    """
    if let result = decode(QueryResult.self, resultJSON, "QueryResult decodes from snake_case") {
        print("PASS QueryResult decodes from snake_case")
        expectEqual(result.columns.first?.name, "id", "ColumnDef.name")
        expectEqual(result.columns.first?.dataType, "INT4", "ColumnDef.dataType from key data_type")
        expectEqual(result.columns.first?.relationOid, 609999, "ColumnDef.relationOid from key relation_oid")
        expectEqual(result.columns.first?.relationAttno, 1, "ColumnDef.relationAttno from key relation_attno")
        expectEqual(result.rowIdentity?.tableKey, "oid:609999", "RowIdentity.tableKey from key table_key")
        expectEqual(result.rowIdentity?.tableDisplay, "tagtest.users",
                    "RowIdentity.tableDisplay from key table_display")
        expectEqual(result.rowIdentity?.tableKeys, ["oid:609999"], "RowIdentity.tableKeys from key table_keys")
        expectEqual(result.rowIdentity?.candidates.first?.kind, "pk", "KeySet.kind")
        expectEqual(result.rowIdentity?.candidates.first?.keyColumns, ["id"],
                    "KeySet.keyColumns from key key_columns")
        // One entry per row, in row order. This is what the grid indexes by row.
        expectEqual(result.rowIdentity?.candidates.first?.keys, ["V1:1", "V1:2"], "KeySet.keys, one per row")
        // The pre-existing keys must still work — a broken CodingKeys enum could
        // otherwise pass every new assertion while losing an old field.
        expectEqual(result.rowCount, 2, "QueryResult.rowCount from key row_count")
        expectEqual(result.executionTimeMs, 3, "QueryResult.executionTimeMs from key execution_time_ms")
        expectEqual(result.hasMore, false, "QueryResult.hasMore from key has_more")
        expectEqual(result.historyEntryId, "h1", "QueryResult.historyEntryId from key history_entry_id")
    }

    // MARK: 3 — an expression-only result decodes with nil identity and nil OIDs

    // `SELECT count(*) FROM ...` has no source table for its one column, so Rust
    // writes explicit nulls and no identity block. This MUST NOT throw: it is the
    // ordinary shape of an aggregate query, not an error case.
    let exprJSON = """
    {"columns":[{"name":"count","data_type":"INT8","relation_oid":null,"relation_attno":null}],\
    "rows":[["7"]],"row_count":1,"execution_time_ms":1,"has_more":false,\
    "history_entry_id":null,"row_identity":null}
    """
    if let result = decode(QueryResult.self, exprJSON, "an expression-only result decodes") {
        print("PASS an expression-only result decodes")
        expectNil(result.columns.first?.relationOid, "an expression column has a nil relationOid")
        expectNil(result.columns.first?.relationAttno, "an expression column has a nil relationAttno")
        expectNil(result.rowIdentity, "an expression-only result has a nil rowIdentity")
        expectEqual(result.columns.first?.dataType, "INT8", "an expression column still carries its dataType")
    }

    // MARK: 4 — a column with the OID keys ABSENT still decodes

    // Query history caches `result_columns` as an opaque JSON string. Rows cached
    // before this change carry no `relation_oid` key at all, and Rust never
    // re-decodes that string — so Swift carries the ENTIRE compatibility burden.
    // If this throws, every older cached history entry stops opening.
    let legacyColumnJSON = #"{"name":"id","data_type":"INT4"}"#
    if let column = decode(ColumnDef.self, legacyColumnJSON, "a column with no OID keys decodes") {
        print("PASS a column with no OID keys decodes")
        expectEqual(column.name, "id", "a legacy cached column keeps its name")
        expectEqual(column.dataType, "INT4", "a legacy cached column keeps its dataType")
        expectNil(column.relationOid, "an absent relation_oid key decodes as nil")
        expectNil(column.relationAttno, "an absent relation_attno key decodes as nil")
    }

    // The same, one level up: a whole cached history payload with legacy columns
    // and no identity block. This is the real shape on disk today.
    let legacyHistoryJSON = """
    {"columns":[{"name":"id","data_type":"INT4"}],"rows":[["1"]],"rowIdentity":null}
    """
    if let data = decode(QueryHistoryResultData.self, legacyHistoryJSON,
                         "a legacy cached history payload decodes") {
        print("PASS a legacy cached history payload decodes")
        expectNil(data.rowIdentity, "a legacy cached history payload has a nil rowIdentity")
        expectNil(data.columns.first?.relationOid, "a legacy cached history column has a nil relationOid")
    }

    // MARK: 5 — the mixed payload

    // `QueryHistoryResultData` renames its OWN fields to camelCase, so the outer
    // key is `rowIdentity`. `rename_all` does not reach inside a nested
    // serde_json::Value, so the identity block keeps the snake_case keys that
    // execute_query wrote. Both conventions in one payload, deliberately.
    let mixedJSON = """
    {"columns":[{"name":"id","data_type":"INT4","relation_oid":609999,"relation_attno":1}],\
    "rows":[["1"],["2"]],\
    "rowIdentity":{"table_key":"oid:609999","table_display":"tagtest.users",\
    "table_keys":["oid:609999"],\
    "candidates":[{"kind":"pk","key_columns":["id"],"keys":["V1:1","V1:2"]}]}}
    """
    if let data = decode(QueryHistoryResultData.self, mixedJSON, "the mixed history payload decodes") {
        print("PASS the mixed history payload decodes")
        // The outer key is camelCase…
        expectTrue(data.rowIdentity != nil, "the camelCase outer key rowIdentity is found")
        // …and the block inside it is snake_case.
        expectEqual(data.rowIdentity?.tableKey, "oid:609999",
                    "the nested block keeps snake_case: table_key -> tableKey")
        expectEqual(data.rowIdentity?.tableKeys, ["oid:609999"], "the nested block's table_keys")
        expectEqual(data.rowIdentity?.candidates.first?.keyColumns, ["id"],
                    "the nested block's key_columns")
        expectEqual(data.rowIdentity?.candidates.first?.keys, ["V1:1", "V1:2"],
                    "the nested block's per-row keys")
        expectEqual(data.columns.first?.relationOid, 609999, "the mixed payload's column OID")
    }

    // MARK: 6 — a tag write payload encodes to camelCase

    // Swift is the ONLY producer of UpsertRowTag, so no Rust test can catch a
    // casing mistake in it: a snake_case key here would simply arrive at serde as
    // an unknown field and the required field would be reported missing at run
    // time. Assert on the wire text itself.
    let upsert = UpsertRowTag(
        connectionId: "c1",
        labelId: "l1",
        note: "check this",
        primaryKind: "pk",
        tableKey: "oid:16543",
        tableDisplay: "public.users",
        identityColumns: ["id", "email"],
        identityValues: ["42", nil],
        keys: [RowTagKey(identityKind: "pk", identityValue: "V1:42")]
    )
    if let encoded = try? JSONEncoder().encode(upsert),
       let wire = String(data: encoded, encoding: .utf8) {
        print("PASS UpsertRowTag encodes")
        for key in ["connectionId", "labelId", "primaryKind", "tableKey", "tableDisplay",
                    "identityColumns", "identityValues", "identityKind", "identityValue"] {
            expectTrue(wire.contains("\"\(key)\""), "the wire payload carries the camelCase key \(key)")
        }
        for key in ["connection_id", "label_id", "primary_kind", "table_key", "table_display",
                    "identity_columns", "identity_values", "identity_kind", "identity_value"] {
            expectTrue(!wire.contains("\"\(key)\""), "the wire payload does NOT carry the snake_case key \(key)")
        }
        // A NULL identity value must go out as a JSON null, not be dropped: the
        // Rust side decodes Vec<Option<String>> and the positions must line up
        // with identityColumns.
        expectTrue(wire.contains("null"), "a nil identityValue is encoded as a JSON null")
        // Round-trips through the same convention, so a write can be read back.
        if let back = decode(UpsertRowTag.self, wire, "UpsertRowTag round-trips") {
            print("PASS UpsertRowTag round-trips")
            expectEqual(back.connectionId, "c1", "round-tripped connectionId")
            expectEqual(back.identityValues.count, 2, "round-tripped identityValues length")
            expectTrue(back.identityValues.count == 2 && back.identityValues[1] == nil,
                       "round-tripped nil identityValue stays nil")
            expectEqual(back.keys.first, RowTagKey(identityKind: "pk", identityValue: "V1:42"),
                        "round-tripped key")
        }
    } else {
        failures += 1
        print("FAIL UpsertRowTag failed to encode at all")
    }

    // The other write payloads use the same convention.
    if let encoded = try? JSONEncoder().encode(CreateTagLabel(name: "Bad data", colorIndex: 2)),
       let wire = String(data: encoded, encoding: .utf8) {
        expectTrue(wire.contains("\"colorIndex\""), "CreateTagLabel encodes colorIndex")
        expectTrue(!wire.contains("\"color_index\""), "CreateTagLabel does not encode color_index")
    } else {
        failures += 1
        print("FAIL CreateTagLabel failed to encode at all")
    }
    // An UpdateTagLabel omits the fields it is not changing, so a nil must not
    // reach Rust as an explicit null for `name` — serde's Option accepts either,
    // but the encoder default (omit) is what keeps the payload minimal.
    if let encoded = try? JSONEncoder().encode(
        UpdateTagLabel(id: "l1", name: nil, colorIndex: 3, sortOrder: nil)),
       let wire = String(data: encoded, encoding: .utf8) {
        expectTrue(wire.contains("\"colorIndex\""), "UpdateTagLabel encodes colorIndex")
        expectTrue(!wire.contains("\"sort_order\""), "UpdateTagLabel does not encode sort_order")
        if let back = decode(UpdateTagLabel.self, wire, "UpdateTagLabel round-trips") {
            expectEqual(back.colorIndex, 3, "round-tripped UpdateTagLabel.colorIndex")
            expectNil(back.name, "round-tripped UpdateTagLabel.name stays nil")
        }
    } else {
        failures += 1
        print("FAIL UpdateTagLabel failed to encode at all")
    }

    // MARK: - appendingPage: the Load More merge

    // Row keys are per row. A merge that replaced the block instead of
    // concatenating would misalign keys against rows, so row N would take
    // row M's tag. These pin the concatenation.
    let page1 = RowIdentity(
        tableKey: "oid:1", tableDisplay: "public.users", tableKeys: ["oid:1"],
        candidates: [
            KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "V1:2"]),
            KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:a", "V1:b"]),
        ])
    let page2 = RowIdentity(
        tableKey: "oid:1", tableDisplay: "public.users", tableKeys: ["oid:1"],
        candidates: [
            KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:3"]),
            KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:c"]),
        ])

    let merged = page1.appendingPage(page2, pageRowCount: 1)
    expectTrue(merged.candidates.count == 2, "a merge keeps both candidates")
    expectTrue(merged.candidates[0].keys == ["V1:1", "V1:2", "V1:3"],
               "pk keys concatenate in row order")
    expectTrue(merged.candidates[1].keys == ["V1:a", "V1:b", "V1:c"],
               "unique keys concatenate in row order")
    expectTrue(merged.tableKey == "oid:1", "the table identity is unchanged by a merge")

    // A later page with NO block: the appended rows get the empty sentinel, so
    // keys stay aligned with rows instead of falling short.
    let noBlock = page1.appendingPage(nil, pageRowCount: 2)
    expectTrue(noBlock.candidates[0].keys == ["V1:1", "V1:2", "", ""],
               "a page with no identity pads with the no-identity sentinel")

    // A later page missing ONE candidate pads only that one.
    let partial = RowIdentity(
        tableKey: "oid:1", tableDisplay: "public.users", tableKeys: ["oid:1"],
        candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:3"])])
    let half = page1.appendingPage(partial, pageRowCount: 1)
    expectTrue(half.candidates[0].keys == ["V1:1", "V1:2", "V1:3"], "the matching candidate extends")
    expectTrue(half.candidates[1].keys == ["V1:a", "V1:b", ""], "the missing candidate pads")

    // Keys must ALWAYS match the row count, whatever the page reports.
    let overlong = RowIdentity(
        tableKey: "oid:1", tableDisplay: "public.users", tableKeys: ["oid:1"],
        candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:3", "V1:4", "V1:5"])])
    let trimmed = page1.appendingPage(overlong, pageRowCount: 1)
    expectTrue(trimmed.candidates[0].keys.count == 3,
               "a page reporting more keys than rows is trimmed, not left misaligned")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
