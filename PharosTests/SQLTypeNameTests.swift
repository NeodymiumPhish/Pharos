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

    // ClickHouse names, as the core puts them on a ClickHouse result.
    let clickHouse: [(String, String)] = [
        ("Nullable(DateTime64(0))", "timestamp"), ("DateTime", "timestamp"), ("DateTime('UTC')", "timestamp"),
        ("DateTime64(3, 'Europe/Berlin')", "timestamp"), ("Date32", "date"), ("Date", "date"),
        ("String", "text"), ("FixedString(16)", "text"), ("LowCardinality(Nullable(String))", "text"),
        ("UInt8", "int2"), ("Int16", "int2"), ("UInt16", "int4"), ("Int32", "int4"), ("UInt32", "int8"),
        ("Int64", "int8"), ("Int8", "int8"), ("UInt64", "numeric"), ("Int256", "numeric"),
        ("Decimal(10, 2)", "numeric"), ("Decimal64(4)", "numeric"), ("Float32", "float4"), ("Float64", "float8"),
        ("Enum8('a' = 1, 'b' = 2)", "enum"), ("Array(UInt32)", "array"), ("Tuple(a Int64, b String)", "tuple"),
        ("Map(String, UInt64)", "map"), ("AggregateFunction(sum, UInt64)", "aggregatefunction"),
        ("IntervalDay", "text"), ("Bool", "bool"), ("UUID", "uuid"), ("JSON", "json"),
        ("Nullable(UInt8)", "int2"),
    ]
    for (ch, want) in clickHouse {
        expect(SQLTypeName.postgresEquivalent(ch) == want, "ClickHouse \(ch) → \(want)")
    }
    // PostgreSQL's own interval spellings are not ClickHouse intervals.
    expect(SQLTypeName.postgresEquivalent("interval") == "interval", "PostgreSQL interval is unchanged")
    expect(SQLTypeName.postgresEquivalent("interval day to second") == "interval day to second",
           "PostgreSQL interval day to second is unchanged")

    // The sites, for the ClickHouse column that started this: time filters.
    expect(PGTypeCategory(dataType: "Nullable(DateTime64(0))") == .temporal, "Nullable(DateTime64(0)) is temporal")
    expect(PGTypeCategory(dataType: "DateTime") == .temporal, "a ::timestamp cast (DateTime) is temporal")
    expect(PGTypeCategory(dataType: "String") == .string, "String is text")
    expect(PGTypeCategory(dataType: "UInt64") == .numeric, "UInt64 is numeric")
    expect(PGTypeCategory(dataType: "Array(UInt32)") == .string, "an Array is not numeric")
    expect(PGTypeCategory(dataType: "IntervalSecond") == .string, "IntervalSecond is not numeric")
    expect(ColumnClassifier.kind(forDataType: "Nullable(DateTime64(0))") == .temporal, "DateTime64 charts as temporal")

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
