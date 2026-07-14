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
