// Standalone test runner for DuckDBLinkParser — the `pharos://duckdb/attach`
// link that attaches a DuckDB database served over HTTP.
//
// Foundation only. Compiled by scripts/test-duckdb-link-parser.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected \(String(describing: expected)), got \(String(describing: actual))")
    }
}

private func expectNil(_ actual: ParsedDuckDBLink?, _ name: String) {
    if actual == nil {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected nil, got \(String(describing: actual))")
    }
}

private let served = "http%3A%2F%2F127.0.0.1%3A8765%2Fdb%2F0a1b%2Ft7091.duckdb"

func runTests() {

    // MARK: The link the Recon to DuckDB app makes

    if let link = DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=\(served)&name=t7091") {
        expectEqual(link.databaseURL.absoluteString, "http://127.0.0.1:8765/db/0a1b/t7091.duckdb", "url is percent-decoded")
        expectEqual(link.alias, "t7091", "name is the alias")
        expectEqual(link.host, "127.0.0.1:8765", "host shows the port")
        expectEqual(link.fileName, "t7091.duckdb", "file name")
    } else {
        failures += 1
        print("FAIL recon link parses")
    }

    // MARK: Alias

    expectEqual(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=\(served)")?.alias, "t7091",
                "no name: the file stem")
    expectEqual(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=\(served)&name=")?.alias, "t7091",
                "empty name: the file stem")
    expectEqual(DuckDBLinkParser.alias(from: "Test Neo (v2)"), "test_neo_v2", "spaces and brackets become one _")
    expectEqual(DuckDBLinkParser.alias(from: "7091"), "db_7091", "leading digit gets db_")
    expectEqual(DuckDBLinkParser.alias(from: "main"), "db_main", "reserved name gets db_")
    expectEqual(DuckDBLinkParser.alias(from: "\"; DROP"), "drop", "quotes cannot reach the SQL")
    expectEqual(DuckDBLinkParser.alias(from: "---"), "db", "nothing usable: db")
    expectEqual(DuckDBLinkParser.alias(from: String(repeating: "a", count: 80)).count, 63, "at most 63 characters")

    // MARK: https, and a quote in the URL (pharos-core doubles it in the ATTACH)

    if let link = DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=https%3A%2F%2Fh.example%2Fa'b.duckdb") {
        expectEqual(link.databaseURL.absoluteString, "https://h.example/a'b.duckdb", "https URL kept whole")
        expectEqual(link.alias, "a_b", "alias from a stem with a quote")
    } else {
        failures += 1
        print("FAIL https link with a quote parses")
    }

    // MARK: Refused

    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach"), "no url")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/open?url=\(served)"), "other action")
    expectNil(DuckDBLinkParser.parse(string: "pharos://other/attach?url=\(served)"), "other host")
    expectNil(DuckDBLinkParser.parse(string: "other://duckdb/attach?url=\(served)"), "other scheme")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=file%3A%2F%2F%2Fetc%2Fpasswd"), "file URL")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=s3%3A%2F%2Fbucket%2Fx.duckdb"), "s3 URL")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=%2Ftmp%2Fx.duckdb"), "a path")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=http%3A%2F%2Fu%3Ap%40h%2Fx.duckdb"),
              "user and password in the URL")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=http%3A%2F%2Fh%2Fx%0A.duckdb"),
              "control character")
    expectNil(DuckDBLinkParser.parse(string: "pharos://duckdb/attach?url=http%3A%2F%2F%2Fx.duckdb"), "no host")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
