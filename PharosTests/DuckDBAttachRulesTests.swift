// Standalone test for DuckDBAttachRules — the Attach PostgreSQL Connection
// sheet's choices and the navigator's attached-database test.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let pg = ConnectionConfig(id: "p", name: "Live Analysis", host: "h", port: 5432, database: "d", username: "u")
    let duck = ConnectionConfig.duckDB(path: "/x.duckdb")
    expect(DuckDBAttachRules.candidates([duck, pg]).map(\.id) == ["p"], "only PostgreSQL records are offered")

    // The same table as pharos-core's default_aliases_are_valid_identifiers.
    for (name, want) in [("Live Analysis", "live_analysis"), ("Ghostnet/ZISK", "ghostnet_zisk"),
                         ("2024 db", "pg_2024_db"), ("  ", "pg"), ("main", "pg_main"), ("WHOIS - CH", "whois_ch")] {
        let got = DuckDBAttachRules.defaultAlias(for: name)
        expect(got == want, "default alias of \"\(name)\" is \(want) (got \(got))")
        expect(DuckDBAttachRules.isValidAlias(got), "\(got) is valid")
    }
    expect(DuckDBAttachRules.isValidAlias(""), "empty means the default")
    for bad in ["Bad Name", "x;drop", "memory", "1abc", "é"] {
        expect(!DuckDBAttachRules.isValidAlias(bad), "\"\(bad)\" is refused")
    }

    var ro = pg
    ro.readOnly = true
    expect(DuckDBAttachRules.forcesReadOnly(ro) && !DuckDBAttachRules.forcesReadOnly(pg), "a read-only record forces read-only")

    expect(DuckDBAttachRules.attachedDatabase(ofSchema: "local_pg.public") == "local_pg", "an attached schema names its database")
    expect(DuckDBAttachRules.attachedDatabase(ofSchema: "main") == nil, "the file's own schema is not attached")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
