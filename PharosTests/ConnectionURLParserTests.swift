// Standalone test runner for ConnectionURLParser — the `postgres://` /
// `postgresql://` link reader behind the Connections form's pre-fill.
//
// Foundation only, no AppKit: the parser deliberately does not know about
// `ConnectionConfig`, so the whole rule set is testable without the app.
// Compiled by scripts/test-connection-url-parser.sh.
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

private func expectNil(_ actual: ParsedConnectionURL?, _ name: String) {
    if actual == nil {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected nil, got \(String(describing: actual))")
    }
}

func runTests() {

    // MARK: A full link — every part present

    if let full = ConnectionURLParser.parse(string:
        "postgresql://u:p%40ss@db.example.com:5433/app?sslmode=require") {
        expectEqual(full.host, "db.example.com", "full link: host")
        expectEqual(full.port, 5433, "full link: port")
        expectEqual(full.user, "u", "full link: user")
        // The password is the point of the percent escape: `p%40ss` is `p@ss`,
        // and an undecoded value would also move the userinfo's `@` split.
        expectEqual(full.password, "p@ss", "full link: password is percent-decoded")
        expectEqual(full.database, "app", "full link: database")
        expectEqual(full.sslMode, .require, "full link: sslmode=require")
        expectEqual(full.passwordWasInURL, true, "full link: passwordWasInURL")
        expectEqual(full.suggestedName, "u@db.example.com/app", "full link: suggested name")
    } else {
        failures += 1
        print("FAIL full link parses")
    }

    // MARK: No port, no password

    if let plain = ConnectionURLParser.parse(string: "postgres://u@localhost/db") {
        expectEqual(plain.host, "localhost", "postgres scheme: host")
        expectEqual(plain.port, nil, "postgres scheme: no port, so nil (the caller supplies 5432)")
        expectEqual(plain.user, "u", "postgres scheme: user")
        expectEqual(plain.password, nil, "postgres scheme: no password")
        expectEqual(plain.passwordWasInURL, false, "postgres scheme: passwordWasInURL is false")
        expectEqual(plain.database, "db", "postgres scheme: database")
        expectEqual(plain.sslMode, nil, "postgres scheme: no sslmode given")
        expectEqual(plain.suggestedName, "u@localhost/db", "postgres scheme: suggested name")
    } else {
        failures += 1
        print("FAIL postgres:// link parses")
    }

    // MARK: Host only

    if let bare = ConnectionURLParser.parse(string: "postgresql://localhost") {
        expectEqual(bare.host, "localhost", "host-only link: host")
        expectEqual(bare.user, nil, "host-only link: no user")
        expectEqual(bare.database, nil, "host-only link: no database")
        expectEqual(bare.port, nil, "host-only link: no port")
        // Neither half of `user@host/database` is present, so the name is the
        // host on its own.
        expectEqual(bare.suggestedName, "localhost", "host-only link: suggested name is the host")
    } else {
        failures += 1
        print("FAIL host-only link parses")
    }

    // MARK: IPv6 literal

    if let v6 = ConnectionURLParser.parse(string: "postgresql://[::1]:5432/db") {
        // The brackets belong to the URL, not to the address: libpq and the
        // form both want `::1`.
        expectEqual(v6.host, "::1", "IPv6 literal: brackets are stripped")
        expectEqual(v6.port, 5432, "IPv6 literal: port")
        expectEqual(v6.database, "db", "IPv6 literal: database")
    } else {
        failures += 1
        print("FAIL IPv6 literal link parses")
    }

    // MARK: Query-parameter form (libpq allows every part to move into the query)

    if let params = ConnectionURLParser.parse(string: "postgresql:///db?host=/tmp&user=x") {
        expectEqual(params.host, "/tmp", "query form: host comes from the query")
        expectEqual(params.user, "x", "query form: user comes from the query")
        expectEqual(params.database, "db", "query form: database still comes from the path")
    } else {
        failures += 1
        print("FAIL query-parameter link parses")
    }

    // A query parameter must NOT win over the authority — libpq's order is the
    // other way round. Chosen so the two rules disagree: both name a host.
    if let precedence = ConnectionURLParser.parse(string:
        "postgresql://u@authority.example:5432/dbname?host=query.example&port=6000&user=q&dbname=other") {
        expectEqual(precedence.host, "authority.example", "precedence: the authority host wins over ?host")
        expectEqual(precedence.port, 5432, "precedence: the authority port wins over ?port")
        expectEqual(precedence.user, "u", "precedence: the authority user wins over ?user")
        expectEqual(precedence.database, "dbname", "precedence: the path database wins over ?dbname")
    } else {
        failures += 1
        print("FAIL precedence link parses")
    }

    // An unknown parameter is ignored rather than rejecting the link.
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/db?application_name=psql&banana=1")?.host,
                "h", "an unknown query parameter is ignored")

    // MARK: Multi-host list — the first host wins
    //
    // `URL(string:)` rejects this outright, so the parser repairs the authority
    // itself; that is why the string entry point exists.
    if let multi = ConnectionURLParser.parse(string: "postgresql://h1:5432,h2:5432/db") {
        expectEqual(multi.host, "h1", "multi-host: the first host is taken")
        expectEqual(multi.port, 5432, "multi-host: the first host's port is taken")
        expectEqual(multi.database, "db", "multi-host: database")
    } else {
        failures += 1
        print("FAIL multi-host link parses")
    }

    // The comma split must happen AFTER the userinfo, not before: a password is
    // free to hold a comma.
    if let multiAuth = ConnectionURLParser.parse(string: "postgresql://u:a%2Cb@h1:5432,h2:5432/db") {
        expectEqual(multiAuth.host, "h1", "multi-host with userinfo: the first host is taken")
        expectEqual(multiAuth.password, "a,b", "multi-host with userinfo: a comma in the password survives")
    } else {
        failures += 1
        print("FAIL multi-host link with userinfo parses")
    }

    // MARK: sslmode mapping

    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=verify-full")?.sslMode,
                .require, "sslmode=verify-full maps to Require")
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=verify-ca")?.sslMode,
                .require, "sslmode=verify-ca maps to Require")
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=allow")?.sslMode,
                .prefer, "sslmode=allow maps to Prefer")
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=disable")?.sslMode,
                .disable, "sslmode=disable maps to Disable")
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=REQUIRE")?.sslMode,
                .require, "sslmode is read case-insensitively")
    // An unreadable value leaves the form's own default standing; it does not
    // silently become Disable.
    expectEqual(ConnectionURLParser.parse(string: "postgres://h/d?sslmode=banana")?.sslMode,
                nil, "an unknown sslmode is nil, not a guess")

    // MARK: Rejected links

    expectNil(ConnectionURLParser.parse(string: "https://x"), "a non-PostgreSQL scheme is refused")
    expectNil(ConnectionURLParser.parse(string: "postgresql://"),
              "a link with no host, database or user is refused")
    expectNil(ConnectionURLParser.parse(string: "postgres://"),
              "the postgres scheme with nothing after it is refused")
    expectNil(ConnectionURLParser.parse(string: "postgresql://%%%"),
              "an unparseable authority is refused")
    expectNil(ConnectionURLParser.parse(string: "not a url at all"),
              "text that is not a URL is refused")

    // MARK: The scheme is matched case-insensitively (Launch Services may vary it)

    expectEqual(ConnectionURLParser.parse(string: "POSTGRESQL://Host/DB")?.host, "Host",
                "the scheme is matched case-insensitively and the host keeps its case")

    // MARK: The URL entry point agrees with the string entry point

    if let url = URL(string: "postgresql://u:p%40ss@db.example.com:5433/app?sslmode=require") {
        expectEqual(ConnectionURLParser.parse(url),
                    ConnectionURLParser.parse(string: url.absoluteString),
                    "parse(URL) and parse(string:) agree")
    } else {
        failures += 1
        print("FAIL the full link builds a URL")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
