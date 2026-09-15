// The pure half of "Explain this error": what the model is and is not shown.
//
// Foundation only. `ErrorExplanationPrompt.swift` deliberately imports nothing
// else, so this binary compiles without FoundationModels, AppKit, MetadataCache
// or the Rust core — and the rules that decide what leaves the app can be
// checked on their own.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectContains(_ haystack: String, _ needle: String, _ name: String) {
    if haystack.contains(needle) { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name) — missing \(needle.debugDescription)")
    }
}

private func expectExcludes(_ haystack: String, _ needle: String, _ name: String) {
    if !haystack.contains(needle) { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name) — should not contain \(needle.debugDescription)")
    }
}

// MARK: - Fixtures

private typealias Prompt = ErrorExplanationPrompt

private let users = Prompt.TableRef(
    schema: "public", table: "users",
    columns: [
        Prompt.Column(name: "id", type: "integer"),
        Prompt.Column(name: "email", type: "text"),
        Prompt.Column(name: "created_at", type: "timestamp"),
    ])

private let orders = Prompt.TableRef(
    schema: "public", table: "orders",
    columns: [
        Prompt.Column(name: "id", type: "integer"),
        Prompt.Column(name: "total", type: "numeric"),
    ])

private let secrets = Prompt.TableRef(
    schema: "private", table: "audit_log",
    columns: [Prompt.Column(name: "payload", type: "jsonb")])

private let everything = Prompt.KnownObjects(tables: [users, orders, secrets])

// MARK: - Tests

func runTests() {
    print("=== ErrorExplanationPrompt ===")

    // Only the named table is described; the other two are not in the prompt at
    // all, not even by name.
    let one = Prompt.build(
        message: "column \"emial\" does not exist at character 8",
        sql: "SELECT emial FROM users",
        knownObjects: everything)
    expectContains(one, "public.users", "names the table the statement uses")
    expectExcludes(one, "orders", "leaves out a table the statement never names")
    expectExcludes(one, "audit_log", "leaves out a table in another schema")

    // A NAMED table brings every column (name and type): the fix for a typo
    // is the column that exists, which the statement by definition does not name.
    expectContains(one, "public.users(id integer, email text, created_at timestamp)",
                   "lists every column of a named table so the model can propose the right one")
    expectExcludes(one, "total numeric", "columns of an unnamed table stay out")

    let named = Prompt.build(
        message: "boom",
        sql: "SELECT id, email FROM users WHERE created_at > now()",
        knownObjects: everything)
    expectContains(named, "public.users(id integer, email text, created_at timestamp)",
                   "lists the columns with their types, in cache order")

    // A table the statement names without naming any column still lists its
    // columns; a named table with NO columns in the cache has no parentheses.
    let noColumns = Prompt.build(
        message: "boom", sql: "SELECT * FROM orders", knownObjects: everything)
    expectContains(noColumns, "known objects: public.orders(id integer, total numeric)",
                   "SELECT * still gets the column list")
    let bare = Prompt.build(
        message: "boom", sql: "SELECT * FROM empty_t",
        knownObjects: Prompt.KnownObjects(tables: [Prompt.TableRef(schema: "public", table: "empty_t", columns: [])]))
    expectContains(bare, "public.empty_t", "a table with no cached columns is still named")
    expectExcludes(bare, "public.empty_t(", "no empty parentheses")

    // The cap: a wide table is cut at `columnCap` with an ellipsis.
    let wide = Prompt.TableRef(schema: "public", table: "wide",
                               columns: (0..<70).map { Prompt.Column(name: "c\($0)", type: "text") })
    let wideCapped = Prompt.build(message: "boom", sql: "SELECT * FROM wide",
                                  knownObjects: Prompt.KnownObjects(tables: [wide]))
    expectContains(wideCapped, "c59 text, …)", "sixty columns then an ellipsis")
    expectExcludes(wideCapped, "c60 text", "the sixty-first column is cut")

    // Case. PostgreSQL folds an unquoted identifier, so the match must too.
    let upper = Prompt.build(
        message: "boom", sql: "SELECT ID FROM USERS", knownObjects: everything)
    expectContains(upper, "public.users(id integer, email text, created_at timestamp)",
                   "matches a table case-insensitively")

    // Quoted identifiers are one token, quotes and all.
    let quoted = Prompt.build(
        message: "boom", sql: "SELECT \"email\" FROM \"users\"", knownObjects: everything)
    expectContains(quoted, "public.users(id integer, email text, created_at timestamp)", "matches a quoted identifier")

    // Schema-qualified: the dot splits, so the table half still matches.
    let qualified = Prompt.build(
        message: "boom", sql: "SELECT * FROM public.orders", knownObjects: everything)
    expectContains(qualified, "public.orders", "matches a schema-qualified table")

    // A string LITERAL is a value, not an identifier. A row that reads 'orders'
    // must not pull the orders table into the prompt.
    let literal = Prompt.build(
        message: "boom",
        sql: "SELECT * FROM users WHERE email = 'orders' AND id = 'audit_log'",
        knownObjects: everything)
    expectContains(literal, "public.users", "the real table is still described")
    expectExcludes(literal, "public.orders", "a table named inside a string literal is not matched")
    expectExcludes(literal, "private.audit_log", "nor one inside a second literal")

    // Nothing matches: no "known objects" line at all, rather than an empty one.
    let none = Prompt.build(
        message: "relation \"pg_clas\" does not exist",
        sql: "SELECT nme FROM pg_class", knownObjects: everything)
    expectExcludes(none, "known objects", "no known-objects line when nothing matches")

    // The message goes in exactly as PostgreSQL wrote it — the `at character`
    // suffix included, because that is the position the answer needs.
    let message = "ERROR: syntax error at or near \"FORM\"\nLINE 1: ... at character 15"
    let verbatim = Prompt.build(message: message, sql: "SELECT 1 FORM x", knownObjects: .none)
    expectContains(verbatim, message, "the message is verbatim")

    // The statement is capped, and the cut is marked.
    let long = String(repeating: "a", count: 10) + String(repeating: "x", count: 6000)
    let capped = Prompt.build(message: "boom", sql: long, knownObjects: .none)
    expect(capped.count < 4500, "a 6 kB statement does not reach the model whole")
    expectContains(capped, Prompt.truncationMarker, "the cut is marked")
    expectEqual(Prompt.cap(long).count, Prompt.sqlCharacterLimit + 1 + Prompt.truncationMarker.count,
                "the cap is exactly sqlCharacterLimit characters plus the marker")
    expectEqual(Prompt.cap("SELECT 1"), "SELECT 1", "a short statement is untouched")

    // Row values have nowhere to enter. `KnownObjects` carries a name and a type
    // per column and nothing else — there is no third field to fill — so the only
    // text in the prompt is the message, the statement and those names. A value
    // that sits in neither cannot appear.
    let planted = "Ada Lovelace"
    let rowSafe = Prompt.build(
        message: "column \"emial\" does not exist",
        sql: "SELECT emial FROM users",
        knownObjects: everything)
    expectExcludes(rowSafe, planted, "no row value reaches the prompt")
    expectEqual(
        Prompt.describe(knownObjects: everything, mentionedIn: "SELECT id FROM users"),
        "public.users(id integer, email text, created_at timestamp)",
        "the whole of what the schema contributes is names and types")

    // And the same, spelled as a fact about the type: a column is two strings.
    let column = Prompt.Column(name: "email", type: "text")
    expectEqual(Prompt.Column(name: column.name, type: column.type), column,
                "a column is its name and its type, and nothing else")

    // MARK: Identifier scan

    expectEqual(Prompt.identifiers(in: "SELECT a.b FROM c"), ["select", "a", "b", "from", "c"],
                "the dot splits and everything folds")
    expectEqual(Prompt.identifiers(in: "SELECT 'x' FROM t"), ["select", "from", "t"],
                "a literal contributes nothing")
    expectEqual(Prompt.identifiers(in: "SELECT \"Mixed Case\" FROM t"),
                ["select", "mixed case", "from", "t"],
                "a quoted identifier keeps its space and folds")
    expectEqual(Prompt.identifiers(in: "SELECT 'it''s' , x FROM t"), ["select", "x", "from", "t"],
                "a doubled quote inside a literal does not end it")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    if failures > 0 { exit(1) }
}
