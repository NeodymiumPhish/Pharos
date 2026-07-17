// Standalone test runner for ColumnClassifier.
// Compiled with Pharos/Models/Charts/{ChartTypes,ColumnClassifier}.swift by
// scripts/test-column-classifier.sh.
import Foundation

var failures = 0
func expectKind(_ dt: String, _ expected: ColumnKind, _ name: String) {
    let actual = ColumnClassifier.kind(forDataType: dt)
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)  expected \(expected) got \(actual)") }
}

func runTests() {
    expectKind("integer", .numeric, "integer")
    expectKind("bigint", .numeric, "bigint")
    expectKind("int8", .numeric, "int8")
    expectKind("numeric", .numeric, "numeric")
    expectKind("double precision", .numeric, "double precision")
    expectKind("money", .numeric, "money")
    expectKind("bigserial", .numeric, "bigserial")
    expectKind("date", .temporal, "date")
    expectKind("timestamp without time zone", .temporal, "timestamp")
    expectKind("timestamptz", .temporal, "timestamptz")
    expectKind("time", .temporal, "time")
    expectKind("text", .categorical, "text")
    expectKind("character varying", .categorical, "varchar")
    expectKind("boolean", .categorical, "boolean")
    expectKind("uuid", .categorical, "uuid")
    expectKind("USER-DEFINED", .categorical, "user-defined fallback")
    expectKind("  Integer ", .numeric, "trims + case-insensitive")
    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
