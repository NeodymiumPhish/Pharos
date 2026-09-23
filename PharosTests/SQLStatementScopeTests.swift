// Standalone tests for SQLStatementScope: what the statement around the
// caret names, and what the caret's position expects next. Foundation only;
// compiled by scripts/test-sql-statement-scope.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

/// `marked` with `|` at the caret.
private func scope(_ marked: String) -> SQLStatementScope {
    let caret = (marked as NSString).range(of: "|").location
    let text = marked.replacingOccurrences(of: "|", with: "")
    return SQLStatementScope.analyze(text, caret: caret)
}

private func clause(_ marked: String) -> SQLStatementScope.Clause { scope(marked).clause }

private typealias Ref = SQLStatementScope.TableRef

private func testTables() {
    // (A comma AFTER a `JOIN … ON` condition does not continue the list; the
    // scanner reads the FROM list only directly after FROM. Rare form.)
    let s = scope("SELECT u.id FROM public.users u, sales.\"Big Table\" JOIN orders AS o ON o.user_id = u.id WHERE |")
    expectEqual(s.tables, [
        Ref(schema: "public", table: "users", alias: "u"),
        Ref(schema: "sales", table: "Big Table", alias: nil),
        Ref(schema: nil, table: "orders", alias: "o"),
    ], "tables: FROM list, JOIN, schema-qualified, quoted, aliases with and without AS")
    expectEqual(s.target, nil, "tables: a SELECT has no target")

    expectEqual(scope("UPDATE users SET name = 'x' WHERE |").target, Ref(schema: nil, table: "users", alias: nil), "target: UPDATE")
    expectEqual(scope("INSERT INTO log (a) VALUES (|").target, Ref(schema: nil, table: "log", alias: nil), "target: INSERT INTO")
    expectEqual(scope("DELETE FROM sales.orders o WHERE |").target, Ref(schema: "sales", table: "orders", alias: "o"), "target: DELETE FROM")
    expectEqual(scope("UPDATE users SET name = 'x' WHERE |").tables.count, 1, "tables: UPDATE target counted once")

    expectEqual(scope("SELECT * FROM users WHERE |").tables.first?.alias, nil, "alias: WHERE is not an alias")
    expectEqual(scope("SELECT * FROM users LIMIT |").tables.first?.alias, nil, "alias: LIMIT is not an alias")
    expectEqual(scope("SELECT * FROM users u WHERE |").tables.first?.alias, "u", "alias: bare alias")
    expectEqual(scope("SELECT * FROM ONLY users u |").tables.first, Ref(schema: nil, table: "users", alias: "u"), "alias: ONLY is skipped")

    let d = scope("SELECT * FROM (SELECT id FROM users) AS sub JOIN orders o ON |")
    expectEqual(d.derivedAliases, ["sub"], "derived: a subquery's alias")
    expectEqual(d.tables, [Ref(schema: nil, table: "users", alias: nil), Ref(schema: nil, table: "orders", alias: "o")],
                "derived: the subquery's tables are collected too (a superset is safe)")

    let c = scope("WITH recent AS (SELECT * FROM orders WHERE d > now()), top (id) AS (SELECT 1) SELECT * FROM recent r JOIN top t ON |")
    expectEqual(c.cteNames, ["recent", "top"], "cte: both names, with a column list")
    expectEqual(c.tables, [Ref(schema: nil, table: "orders", alias: nil), Ref(schema: nil, table: "recent", alias: "r"), Ref(schema: nil, table: "top", alias: "t")],
                "cte: tables inside the CTE bodies are collected too")

    let a = scope("SELECT count(*) AS total, u.name AS user_name, x FROM users u ORDER BY |")
    expectEqual(a.selectAliases, ["total", "user_name"], "select aliases: AS names followed by , or FROM")
    expectEqual(a.tables.first?.alias, "u", "select aliases: the table alias is not one of them")
    expectEqual(scope("SELECT a FROM users AS u WHERE |").selectAliases, [], "select aliases: a table's AS alias is excluded")
}

private func testClauses() {
    expectEqual(clause("|"), .start, "clause: empty")
    expectEqual(clause("SEL|"), .start, "clause: typing the first word")
    expectEqual(clause("SELECT 1; |"), .start, "clause: after ;")
    expectEqual(clause("SELECT |"), .select, "clause: after SELECT")
    expectEqual(clause("SELECT DISTINCT |"), .select, "clause: after DISTINCT")
    expectEqual(clause("SELECT id, |"), .select, "clause: comma in the select list")
    expectEqual(clause("SELECT id, na| FROM users"), .select, "clause: typing a column with FROM after the caret")
    expectEqual(clause("SELECT * |"), .afterExpression(.select), "clause: SELECT * then space → FROM")
    expectEqual(clause("SELECT id |"), .afterExpression(.select), "clause: after a select expression")
    expectEqual(clause("SELECT * FROM |"), .from, "clause: after FROM")
    expectEqual(clause("SELECT * FROM us|"), .from, "clause: typing a table")
    expectEqual(clause("SELECT * FROM users u JOIN |"), .from, "clause: after JOIN")
    expectEqual(clause("SELECT * FROM users LEFT |"), .keywords(["JOIN", "OUTER JOIN"]), "clause: after LEFT")
    expectEqual(clause("SELECT * FROM users |"), .afterTableRef(.from), "clause: table complete → clause keywords")
    expectEqual(clause("SELECT * FROM users u |"), .afterTableRef(.from), "clause: aliased table complete")
    expectEqual(clause("UPDATE users |"), .afterTableRef(.update), "clause: UPDATE's table complete → SET")
    expectEqual(clause("SELECT * FROM (SELECT id FROM users) AS sub |"), .afterTableRef(.from), "clause: derived table complete")
    expectEqual(clause("INSERT INTO log (a) VALUES (1) ON |"), .keywords(["CONFLICT"]), "clause: ON after VALUES")
    expectEqual(clause("SELECT * FROM users, |"), .from, "clause: comma in FROM")
    expectEqual(clause("SELECT * FROM users WHERE |"), .condition(valuePosition: false), "clause: after WHERE")
    expectEqual(clause("SELECT * FROM users WHERE id = 1 AND |"), .condition(valuePosition: false), "clause: after AND")
    expectEqual(clause("SELECT * FROM users WHERE id = 1 OR |"), .condition(valuePosition: false), "clause: after OR")
    expectEqual(clause("SELECT * FROM users u JOIN orders o ON |"), .condition(valuePosition: false), "clause: after ON")
    expectEqual(clause("SELECT * FROM users WHERE id = |"), .condition(valuePosition: true), "clause: after = → value")
    expectEqual(clause("SELECT * FROM users WHERE id IN (|"), .condition(valuePosition: true), "clause: inside IN (")
    expectEqual(clause("SELECT * FROM users WHERE name LIKE |"), .condition(valuePosition: true), "clause: after LIKE")
    expectEqual(clause("SELECT * FROM users WHERE id = 1 |"), .afterExpression(.condition), "clause: condition complete")
    expectEqual(clause("SELECT * FROM users WHERE (a = 1 OR b = 2) |"), .afterExpression(.condition), "clause: a closed group is one expression")
    expectEqual(clause("SELECT * FROM users WHERE lower(|"), .condition(valuePosition: false), "clause: function arguments")
    expectEqual(clause("SELECT * FROM users WHERE EXISTS (|"), .condition(valuePosition: true), "clause: EXISTS ( → a subquery may start")
    expectEqual(clause("SELECT * FROM users WHERE id IN (SELECT |"), .select, "clause: a subquery has its own SELECT")
    expectEqual(clause("SELECT * FROM users WHERE id IN (SELECT user_id FROM |"), .from, "clause: a subquery's FROM")
    expectEqual(clause("SELECT * FROM users GROUP BY |"), .groupOrOrder, "clause: after GROUP BY")
    expectEqual(clause("SELECT * FROM users GROUP |"), .keywords(["BY"]), "clause: after GROUP")
    expectEqual(clause("SELECT * FROM users ORDER BY |"), .groupOrOrder, "clause: after ORDER BY")
    expectEqual(clause("SELECT * FROM users ORDER BY name, |"), .groupOrOrder, "clause: comma in ORDER BY")
    expectEqual(clause("SELECT * FROM users ORDER BY name |"), .afterOrderColumn, "clause: after an ORDER BY column")
    expectEqual(clause("SELECT * FROM users ORDER BY name DESC |"), .afterExpression(.orderBy), "clause: after DESC")
    expectEqual(clause("SELECT * FROM users GROUP BY a HAVING |"), .condition(valuePosition: false), "clause: after HAVING")
    expectEqual(clause("SELECT * FROM users LIMIT |"), .value, "clause: after LIMIT")
    expectEqual(clause("UPDATE users SET |"), .set, "clause: after SET")
    expectEqual(clause("UPDATE users SET name = |"), .condition(valuePosition: true), "clause: SET value")
    expectEqual(clause("UPDATE users SET name = 'x', |"), .set, "clause: comma in SET")
    expectEqual(clause("UPDATE users SET name = 'x' WHERE |"), .condition(valuePosition: false), "clause: UPDATE's WHERE")
    expectEqual(clause("UPDATE |"), .from, "clause: after UPDATE")
    expectEqual(clause("INSERT INTO |"), .from, "clause: after INSERT INTO")
    expectEqual(clause("INSERT |"), .keywords(["INTO"]), "clause: after INSERT")
    expectEqual(clause("INSERT INTO log (|"), .insertColumns, "clause: INSERT column list")
    expectEqual(clause("INSERT INTO log (a, |"), .insertColumns, "clause: comma in the INSERT column list")
    expectEqual(clause("INSERT INTO log (a) |"), .afterExpression(.insertInto), "clause: after the column list → VALUES")
    expectEqual(clause("INSERT INTO log (a) VALUES (|"), .value, "clause: inside VALUES (")
    expectEqual(clause("INSERT INTO log (a) VALUES (1, |"), .value, "clause: comma in VALUES")
    expectEqual(clause("DELETE |"), .keywords(["FROM"]), "clause: after DELETE")
    expectEqual(clause("DELETE FROM |"), .from, "clause: after DELETE FROM")
    expectEqual(clause("DELETE FROM users WHERE |"), .condition(valuePosition: false), "clause: DELETE's WHERE")
    expectEqual(clause("DELETE FROM users WHERE id = 1 RETURNING |"), .select, "clause: RETURNING lists columns")
    expectEqual(clause("TRUNCATE |"), .from, "clause: after TRUNCATE")
    expectEqual(clause("ALTER TABLE |"), .from, "clause: after ALTER TABLE")
    expectEqual(clause("DROP TABLE |"), .from, "clause: after DROP TABLE")
    expectEqual(clause("CREATE TABLE |"), .none, "clause: CREATE TABLE names something new")
    expectEqual(clause("CREATE |"), .keywords(["TABLE", "INDEX", "VIEW", "MATERIALIZED VIEW", "SCHEMA", "FUNCTION", "SEQUENCE", "TYPE", "EXTENSION"]), "clause: after CREATE")
    expectEqual(clause("SELECT id AS |"), .none, "clause: after AS nothing is offered")
    expectEqual(clause("WITH |"), .none, "clause: after WITH nothing is offered")
    expectEqual(clause("WITH r AS (|"), .start, "clause: a CTE body starts a statement")
    expectEqual(clause("EXPLAIN |"), .start, "clause: after EXPLAIN")
    expectEqual(clause("SELECT 1 UNION |"), .start, "clause: after UNION")
    expectEqual(clause("SELECT count(*) OVER (|"), .afterExpression(.window), "clause: inside OVER (")
    expectEqual(clause("SELECT a::|"), .none, "clause: after :: a type is named")
    expectEqual(clause("SELECT * FROM users WHERE name = 'a|b'"), .none, "clause: inside a string")
    expectEqual(clause("SELECT * -- comment |"), .none, "clause: inside a comment")
    expectEqual(clause("SELECT * FROM users u WHERE u.|"), .member(qualifier: "u"), "clause: alias.")
    expectEqual(clause("SELECT * FROM public.|"), .member(qualifier: "public"), "clause: schema.")
    expectEqual(clause("SELECT public.users.|"), .member(qualifier: "public.users"), "clause: schema.table.")
    expectEqual(clause("SELECT u.na| FROM users u"), .member(qualifier: "u"), "clause: typing after alias.")
    expectEqual(clause("SELECT \"My Table\".|"), .member(qualifier: "My Table"), "clause: quoted qualifier")
    expectEqual(clause("SELECT .|"), .none, "clause: a dot after nothing")
    expectEqual(clause("SELECT 1.|"), .none, "clause: a dot after a number is a number")
    expectEqual(clause("SELECT (a).|"), .none, "clause: a dot after ) is not a qualifier")
    expectEqual(clause("SELECT * FROM users WHERE a * |"), .condition(valuePosition: true), "clause: * as an operator")
    expectEqual(clause("SELECT * FROM t WHERE x = {{ip}} |"), .afterExpression(.condition), "clause: a variable is an expression")
}

private func testTyped() {
    expectEqual(scope("SELECT * FROM us|").typed, "us", "typed: the identifier before the caret")
    expectEqual(scope("SELECT * FROM |").typed, "", "typed: nothing after a space")
    expectEqual(scope("SELECT u.na|").typed, "na", "typed: the part after the dot")
}

private func testStatements() {
    // Two statements: the caret's own segment is analysed.
    let s = scope("SELECT * FROM orders; SELECT * FROM users u WHERE |")
    expectEqual(s.tables, [Ref(schema: nil, table: "users", alias: "u")], "segments: only the caret's statement is read")
    expectEqual(s.clause, .condition(valuePosition: false), "segments: the caret's clause")
}

func runTests() {
    testTables()
    testClauses()
    testTyped()
    testStatements()
    if failures == 0 { print("\nAll statement scope tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
