// Standalone test runner for TagComposer. Compiled with the implementation by
// scripts/test-tag-composer.sh.
import Foundation

var failures = 0

func expect(_ ok: Bool, _ name: String) {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func identity(_ candidates: [KeySet]) -> RowIdentity {
    RowIdentity(tableKey: "oid:1", tableDisplay: "t", tableKeys: ["oid:1"],
                candidates: candidates)
}

func compose(row: Int, columns: [String], values: [String?],
             identity id: RowIdentity?) -> Result<UpsertRowTag, TagComposer.Failure> {
    TagComposer.upsert(row: row, columns: columns, rowValues: values,
                       identity: id, connectionId: "c", labelId: "L", note: nil)
}

// `UpsertRowTag` is not Equatable, so a whole-Result compare cannot compile.
// Failures are asserted through this extractor instead.
func failureOf(_ r: Result<UpsertRowTag, TagComposer.Failure>) -> TagComposer.Failure? {
    if case .failure(let f) = r { return f }
    return nil
}

func runTests() {
    let pk = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "V1:2"])
    let unique = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V6:a@b.co", ""])

    // A strong row: one RowTagKey per candidate that holds a key.
    switch compose(row: 0, columns: ["id", "email", "name"],
                   values: ["1", "a@b.co", "Ada"], identity: identity([pk, unique])) {
    case .success(let up):
        expect(up.keys == [RowTagKey(identityKind: "pk", identityValue: "V1:1"),
                           RowTagKey(identityKind: "unique", identityValue: "V6:a@b.co")],
               "both candidate keys are copied verbatim")
        expect(up.primaryKind == "pk", "the first contributing candidate names the kind")
        expect(up.identityColumns == ["id"] && up.identityValues == ["1"],
               "the primary candidate's columns and the row's values are stored")
        expect(up.tableKey == "oid:1" && up.tableDisplay == "t", "the table travels")
        expect(up.connectionId == "c" && up.labelId == "L", "the ids travel")
    case .failure: expect(false, "a keyed row composes")
    }

    // The empty-key sentinel: a candidate with an empty key contributes nothing.
    switch compose(row: 1, columns: ["id", "email"], values: ["2", nil],
                   identity: identity([pk, unique])) {
    case .success(let up):
        expect(up.keys == [RowTagKey(identityKind: "pk", identityValue: "V1:2")],
               "an empty key in one candidate is skipped, the other survives")
        expect(up.primaryKind == "pk", "the surviving candidate names the kind")
    case .failure: expect(false, "one empty candidate does not block the row")
    }

    // Every candidate empty: the row has no identity and cannot be tagged.
    let holes = KeySet(kind: "pk", keyColumns: ["id"], keys: [""])
    expect(failureOf(compose(row: 0, columns: ["id"], values: [nil],
                             identity: identity([holes]))) == .noKeyValue,
           "a row with no key value refuses")

    // A key array shorter than the row index degrades, never traps.
    expect(failureOf(compose(row: 5, columns: ["id"], values: ["9"],
                             identity: identity([pk]))) == .noKeyValue,
           "a short key array refuses the uncovered row")

    // The fingerprint tier: empty candidates, whole row stored, Swift encodes.
    switch compose(row: 0, columns: ["b", "a"], values: ["2", nil],
                   identity: identity([])) {
    case .success(let up):
        expect(up.primaryKind == "fingerprint", "an empty candidate set is the weak tier")
        expect(up.identityColumns == ["b", "a"], "every column is stored, result order")
        expect(up.identityValues == ["2", nil], "every value is stored, NULL as nil")
        expect(up.keys.count == 1 && up.keys[0].identityKind == "fingerprint",
               "one fingerprint key")
        expect(up.keys[0].identityValue == RowFingerprint.encode(columns: ["b", "a"],
                                                                 values: ["2", nil]),
               "the key is the canonical encoding")
    case .failure: expect(false, "a weak row composes")
    }

    // No identity block at all: refuse with the reason the UI shows.
    expect(failureOf(compose(row: 0, columns: ["c"], values: ["1"], identity: nil))
               == .noSourceTable,
           "no identity block refuses with noSourceTable")

    // Shape mismatches are core bugs and must degrade.
    expect(failureOf(compose(row: 0, columns: ["a"], values: [], identity: identity([])))
               == .malformedRow,
           "a column/value mismatch refuses")
    let ghost = KeySet(kind: "pk", keyColumns: ["gone"], keys: ["V1:1"])
    expect(failureOf(compose(row: 0, columns: ["id"], values: ["1"],
                             identity: identity([ghost]))) == .malformedRow,
           "a key column missing from the result refuses")

    expect(failureOf(compose(row: -1, columns: ["id"], values: ["1"],
                             identity: identity([pk]))) == .malformedRow,
           "a negative row index refuses instead of trapping")

    expect(failureOf(compose(row: 0, columns: ["id"], values: [],
                             identity: identity([pk]))) == .malformedRow,
           "a strong row with too few values refuses")

    // The note passes through.
    if case .success(let up) = TagComposer.upsert(
        row: 0, columns: ["id"], rowValues: ["1"],
        identity: identity([pk]), connectionId: "c", labelId: "L", note: "hot"
    ) { expect(up.note == "hot", "the note travels") } else { expect(false, "note case composes") }

    if failures == 0 { print("\nAll TagComposer tests passed.") }
    else { print("\n\(failures) failure(s)."); exit(1) }
}
