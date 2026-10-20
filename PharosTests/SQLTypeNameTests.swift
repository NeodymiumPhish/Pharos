// Standalone test for SQLTypeName and the type-name sites that read it:
// DuckDB's names classify like their PostgreSQL equivalents, and every
// PostgreSQL name is unchanged.
import AppKit

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // PostgreSQL names pass through (lowercased, trimmed).
    for pg in ["INT4", "FLOAT8", "NUMERIC", "TIMESTAMPTZ", "BOOL", "TEXT", "JSONB", "INT4[]", "BYTEA", "double precision"] {
        expect(SQLTypeName.postgresEquivalent(pg) == pg.lowercased(), "PostgreSQL \(pg) is unchanged")
    }
    let map: [(String, String)] = [
        ("DOUBLE", "float8"), ("FLOAT", "float4"), ("DECIMAL(18,3)", "numeric"), ("HUGEINT", "numeric"),
        ("TINYINT", "int2"), ("UBIGINT", "numeric"), ("TIMESTAMP_NS", "timestamp"), ("BLOB", "bytea"),
        ("INTEGER[]", "integer[]"), ("DOUBLE[]", "float8[]"), ("INTEGER[3]", "integer[]"),
        ("STRUCT(a INTEGER)", "struct"), ("MAP(VARCHAR, INTEGER)", "map"), ("ENUM('a', 'b')", "enum"),
        ("TIMESTAMP WITH TIME ZONE", "timestamp with time zone"), ("VARCHAR", "varchar"), ("BOOLEAN", "boolean"),
    ]
    for (duck, want) in map {
        expect(SQLTypeName.postgresEquivalent(duck) == want, "DuckDB \(duck) → \(want)")
    }

    // The sites.
    expect(PGTypeCategory(dataType: "DOUBLE") == .numeric, "DOUBLE is numeric for filters")
    expect(PGTypeCategory(dataType: "TIMESTAMP_NS") == .temporal, "TIMESTAMP_NS is temporal")
    expect(PGTypeCategory(dataType: "STRUCT(a INTEGER)") == .string, "a STRUCT is not numeric")
    expect(PGTypeCategory(dataType: "MAP(VARCHAR, INTEGER)") == .string, "a MAP is not numeric")
    expect(PGTypeCategory(dataType: "BOOLEAN") == .boolean, "BOOLEAN is boolean")
    expect(PGTypeCategory(dataType: "INTEGER[]") == .array, "INTEGER[] is an array")
    expect(ColumnTypeIcon.symbolName(forDataType: "DOUBLE") == ColumnTypeIcon.symbolName(forDataType: "FLOAT8"),
           "DOUBLE gets the number icon")
    expect(ColumnTypeIcon.symbolName(forDataType: "DECIMAL(18,3)") == ColumnTypeIcon.symbolName(forDataType: "NUMERIC"),
           "DECIMAL(18,3) gets the number icon")
    expect(ColumnClassifier.kind(forDataType: "HUGEINT") == .numeric, "HUGEINT charts as numeric")
    expect(ColumnClassifier.kind(forDataType: "TIMESTAMP WITH TIME ZONE") == .temporal, "TIMESTAMPTZ charts as temporal")
    expect(ColumnClassifier.kind(forDataType: "STRUCT(a INTEGER)") == .categorical, "a STRUCT charts as categorical")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
