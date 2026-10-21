// Standalone test for DataFiles — what a dropped or opened data file is,
// and what goes into a card for it.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    expect(DataFiles.kind(of: u("/d/a.CSV")) == .csv && DataFiles.kind(of: u("/d/a.tsv")) == .tsv, "csv, tsv in any case")
    expect(DataFiles.kind(of: u("/d/a.jsonl")) == .ndjson && DataFiles.kind(of: u("/d/a.json")) == .json, "json kinds")
    expect(DataFiles.kind(of: u("/d/a.parquet")) == .parquet && DataFiles.kind(of: u("/d/a.xlsx")) == .xlsx, "parquet, xlsx")
    expect(DataFiles.kind(of: u("/d/a.duckdb")) == .duckdb && !DataFiles.isDataFile(u("/d/a.duckdb")), "a database is no data file")
    expect(!DataFiles.isDataFile(u("/d/a.sql")) && !DataFiles.isDataFile(URL(string: "https://x/a.csv")!),
           ".sql and a web URL are not data files")

    expect(DataFiles.insertion(for: [u("/d/sales.csv")], cardIsEmpty: true) == "SELECT * FROM read_csv('/d/sales.csv')",
           "an empty card gets a whole query")
    expect(DataFiles.insertion(for: [u("/d/sales.csv")], cardIsEmpty: false) == "'/d/sales.csv'",
           "a card with text gets the quoted path")
    expect(DataFiles.insertion(for: [u("/d/it's.parquet")], cardIsEmpty: true) == "SELECT * FROM read_parquet('/d/it''s.parquet')",
           "a quote in the path is doubled")
    expect(DataFiles.insertion(for: [u("/d/a.csv"), u("/d/b.csv")], cardIsEmpty: true)
           == "SELECT * FROM read_csv(['/d/a.csv', '/d/b.csv'], union_by_name = true)", "several of one kind: one reader")
    expect(DataFiles.insertion(for: [u("/d/a.xlsx"), u("/d/b.xlsx")], cardIsEmpty: true)
           == "SELECT * FROM read_xlsx('/d/a.xlsx')\nUNION ALL BY NAME\nSELECT * FROM read_xlsx('/d/b.xlsx')",
           "Excel takes one file per reader")
    expect(DataFiles.insertion(for: [u("/d/a.csv"), u("/d/b.json")], cardIsEmpty: true) == "'/d/a.csv'\n'/d/b.json'",
           "mixed kinds: one path per line")
    expect(DataFiles.insertion(for: [u("/d/./x/../a.csv")], cardIsEmpty: false) == "'/d/a.csv'", "paths are standardized")

    expect(DataFiles.createTableSQL(for: u("/d/a.csv"), schema: "main", table: "a")
           == "CREATE TABLE \"main\".\"a\" AS FROM read_csv('/d/a.csv')", "CREATE TABLE … AS FROM a reader")
    expect(DataFiles.createTableSQL(for: u("/d/a.csv"), schema: "main", table: "a", nullString: "\\N")
           == "CREATE TABLE \"main\".\"a\" AS FROM read_csv('/d/a.csv', nullstr = '\\N')", "the NULL literal for CSV")
    expect(DataFiles.createTableSQL(for: u("/d/a.parquet"), schema: "main", table: "a", nullString: "NULL")
           == "CREATE TABLE \"main\".\"a\" AS FROM read_parquet('/d/a.parquet')", "no nullstr for Parquet")
    expect(DataFiles.createTableSQL(for: u("/d/a.sql"), schema: "main", table: "a") == nil, "no table from a .sql file")
    expect(DataFiles.tableName(for: u("/d/Sales 2024-Q1.csv")) == "sales_2024_q1", "a table name from the stem")
    expect(DataFiles.tableName(for: u("/d/2024.csv")) == "t_2024", "a leading digit gets a prefix")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
