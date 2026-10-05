import Foundation

// Tests for the pure half of the "Describe a query" pipeline: DraftCatalog,
// SQLDraftRanker, SQLDraftPrompt and SQLDraftChecker. Run by
// scripts/test-sql-draft-pipeline.sh. The FoundationModels sessions in
// SQLDraft.swift are not compiled here; scripts/eval-sql-draft.sh grades
// them against the real model.

private var failures = 0
private var passes = 0

private func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    expect(a == b, "\(message)\n    got:      \(a)\n    expected: \(b)", line: line)
}

// MARK: - Fixture

private typealias Key = DraftCatalog.TableKey
private typealias Source = DraftCatalog.SourceColumn

private func cols(_ spec: [(String, String, Bool)]) -> [Source] {
    spec.map { Source(name: $0.0, type: $0.1, isPrimaryKey: $0.2) }
}

private let orders = Key(schema: "sales", name: "orders")
private let customers = Key(schema: "sales", name: "customers")
private let items = Key(schema: "sales", name: "order_items")
private let products = Key(schema: "sales", name: "products")
private let shipments = Key(schema: "sales", name: "shipments")
private let returns = Key(schema: "sales", name: "ReturnRequests")
private let employees = Key(schema: "hr", name: "employees")
private let skills = Key(schema: "hr", name: "skills")
private let employeeSkills = Key(schema: "hr", name: "employee_skills")
private let countries = Key(schema: "public", name: "countries")

private func fixture() -> DraftCatalog {
    let columns: [Key: [Source]] = [
        orders: cols([("id", "bigint", true), ("customer_id", "bigint", false), ("status", "USER-DEFINED", false),
                      ("placed_at", "timestamp with time zone", false), ("sales_rep_id", "integer", false)]),
        customers: cols([("id", "bigint", true), ("name", "text", false), ("country_code", "character", false),
                         ("signed_up_at", "timestamp with time zone", false)]),
        items: cols([("order_id", "bigint", true), ("line_no", "integer", true), ("product_id", "integer", false),
                     ("quantity", "integer", false), ("unit_price", "numeric", false)]),
        products: cols([("id", "integer", true), ("name", "text", false), ("sku", "text", false),
                        ("unit_price", "numeric", false), ("discontinued", "boolean", false)]),
        shipments: cols([("id", "bigint", true), ("order_id", "bigint", false), ("carrier", "text", false),
                         ("tracking_no", "text", false)]),
        returns: cols([("id", "bigint", true), ("orderId", "bigint", false), ("requestedAt", "timestamp with time zone", false)]),
        employees: cols([("id", "integer", true), ("first_name", "text", false), ("last_name", "text", false),
                         ("manager_id", "integer", false)]),
        skills: cols([("id", "integer", true), ("name", "text", false)]),
        employeeSkills: cols([("employee_id", "integer", true), ("skill_id", "integer", true), ("level", "smallint", false)]),
        countries: cols([("code", "character(2)", true), ("name", "text", false), ("region", "text", false)]),
    ]
    let sales = SchemaDraftFacts(
        tableComments: ["orders": "one row per customer order"],
        columns: [.init(table: "orders", name: "status", type: "sales.order_status", comment: nil),
                  .init(table: "order_items", name: "unit_price", type: "numeric(10,2)", comment: "price at time of sale")],
        foreignKeys: [
            .init(table: "orders", columns: ["customer_id"], refSchema: "sales", refTable: "customers", refColumns: ["id"]),
            .init(table: "orders", columns: ["sales_rep_id"], refSchema: "hr", refTable: "employees", refColumns: ["id"]),
            .init(table: "order_items", columns: ["order_id"], refSchema: "sales", refTable: "orders", refColumns: ["id"]),
            .init(table: "order_items", columns: ["product_id"], refSchema: "sales", refTable: "products", refColumns: ["id"]),
            .init(table: "shipments", columns: ["order_id"], refSchema: "sales", refTable: "orders", refColumns: ["id"]),
            .init(table: "ReturnRequests", columns: ["orderId"], refSchema: "sales", refTable: "orders", refColumns: ["id"]),
            .init(table: "customers", columns: ["country_code"], refSchema: "public", refTable: "countries", refColumns: ["code"]),
            // A key to a table the catalogue does not have: kept on the
            // column, never a link.
            .init(table: "products", columns: ["id"], refSchema: "archive", refTable: "old_products", refColumns: ["id"]),
        ],
        enums: [.init(type: "sales.order_status", labels: ["pending", "paid", "shipped", "cancelled"])])
    let hr = SchemaDraftFacts(
        foreignKeys: [
            .init(table: "employees", columns: ["manager_id"], refSchema: "hr", refTable: "employees", refColumns: ["id"]),
            .init(table: "employee_skills", columns: ["employee_id"], refSchema: "hr", refTable: "employees", refColumns: ["id"]),
            .init(table: "employee_skills", columns: ["skill_id"], refSchema: "hr", refTable: "skills", refColumns: ["id"]),
        ])
    return DraftCatalog(columns: columns, facts: ["sales": sales, "hr": hr])
}

// MARK: - Catalog

private func testShortTypes() {
    let cases: [(String, String)] = [
        ("timestamp with time zone", "timestamptz"),
        ("timestamp without time zone", "timestamp"),
        ("timestamp(3) with time zone", "timestamptz(3)"),
        ("character varying(80)", "varchar(80)"),
        ("character varying", "varchar"),
        ("character(2)", "char(2)"),
        ("character", "char"),
        ("integer", "int"),
        ("integer[]", "int[]"),
        ("boolean", "bool"),
        ("double precision", "float8"),
        ("numeric(10,2)", "numeric(10,2)"),
        ("sales.order_status", "sales.order_status"),
    ]
    for (long, short) in cases {
        expectEqual(DraftCatalog.shortType(long), short, "shortType(\(long))")
    }
}

private func testQuoting() {
    expectEqual(DraftCatalog.quoted("orders"), "orders", "a folded name stays bare")
    expectEqual(DraftCatalog.quoted("order_items2"), "order_items2", "digits and underscores stay bare")
    expectEqual(DraftCatalog.quoted("ReturnRequests"), "\"ReturnRequests\"", "mixed case is quoted")
    expectEqual(DraftCatalog.quoted("order"), "\"order\"", "a reserved word is quoted")
    expectEqual(DraftCatalog.quoted("2fa"), "\"2fa\"", "a leading digit is quoted")
    expectEqual(DraftCatalog.quoted("a\"b"), "\"a\"\"b\"", "an inner quote is doubled")
    expectEqual(returns.sql, "sales.\"ReturnRequests\"", "a key writes its quotes")
}

private func testFactsOverlay() {
    let catalog = fixture()
    let status = catalog.table(orders)?.columns.first { $0.name == "status" }
    expectEqual(status?.type, "sales.order_status", "facts replace USER-DEFINED with the enum's name")
    expectEqual(status?.enumLabels, ["pending", "paid", "shipped", "cancelled"], "the enum's labels")
    let price = catalog.table(items)?.columns.first { $0.name == "unit_price" }
    expectEqual(price?.type, "numeric(10,2)", "a facts type wins")
    expectEqual(price?.comment, "price at time of sale", "a column comment")
    let placed = catalog.table(orders)?.columns.first { $0.name == "placed_at" }
    expectEqual(placed?.type, "timestamptz", "a cache type is shortened")
    expectEqual(catalog.table(orders)?.comment, "one row per customer order", "a table comment")
    let rep = catalog.table(orders)?.columns.first { $0.name == "sales_rep_id" }
    expectEqual(rep?.reference, DraftCatalog.Reference(table: employees, column: "id"), "a cross-schema key")
    let productID = catalog.table(products)?.columns.first { $0.name == "id" }
    expectEqual(productID?.reference?.table, Key(schema: "archive", name: "old_products"),
                "a key to an unloaded table stays on the column")
    expect(!catalog.links.contains { $0.to.schema == "archive" }, "but is not a link")
    expect(catalog.isLinked(orders, customers), "orders → customers is a link")
    expect(catalog.isLinked(customers, orders), "links work both ways")
    expectEqual(Set(catalog.neighbours(of: orders)), Set([customers, employees, items, shipments, returns]),
                "neighbours of orders, both directions")
}

private func testResolve() {
    let catalog = fixture()
    expectEqual(catalog.resolve(schema: "sales", table: "ORDERS", searchPath: [])?.key, orders, "explicit, any case")
    expectEqual(catalog.resolve(schema: nil, table: "orders", searchPath: ["sales"])?.key, orders, "by search path")
    expectEqual(catalog.resolve(schema: nil, table: "skills", searchPath: ["sales", "public"])?.key, skills,
                "a unique name anywhere")
    expect(catalog.resolve(schema: "hr", table: "orders", searchPath: []) == nil, "the wrong schema")
    expect(catalog.resolve(schema: nil, table: "nope", searchPath: ["sales"]) == nil, "an unknown name")
}

// MARK: - Ranker

private func testWords() {
    expectEqual(SQLDraftRanker.nameWords("OrderItems"), ["order", "item"], "camel case splits")
    expectEqual(SQLDraftRanker.nameWords("order_items2"), ["order", "item"], "snake case splits, digits drop")
    expectEqual(SQLDraftRanker.nameWords("categories"), ["category"], "ies → y")
    expectEqual(SQLDraftRanker.requestWords("Each employee with their manager's name"), ["employee", "manager"],
                "stop words go, possessives fold")
    expectEqual(SQLDraftRanker.requestWords("customers who have never placed an order"),
                ["customer", "placed", "order"], "order is a thing, not a clause")
    expectEqual(SQLDraftRanker.similarity("ship", "shipment"), 0.6, "a prefix of four letters")
    expectEqual(SQLDraftRanker.similarity("id", "idea"), 0, "a short prefix is noise")
}

private func testShortlist() {
    let catalog = fixture()
    let never = SQLDraftRanker.shortlist("customers who have never placed an order", in: catalog, defaultSchema: "sales")
    expectEqual(Array(never.prefix(2)).map(\.key).sorted(), [customers, orders].sorted(), "both named tables lead")

    let carrier = SQLDraftRanker.shortlist("shipped orders with their carrier and tracking number",
                                           in: catalog, defaultSchema: "sales")
    expect(carrier.contains { $0.key == shipments && !$0.isNeighbour }, "columns find shipments: \(carrier)")

    let manager = SQLDraftRanker.shortlist("each employee with their manager", in: catalog, defaultSchema: "hr")
    expectEqual(manager.first?.key, employees, "employees first")
    expect(manager.contains { $0.key == employeeSkills && !$0.isNeighbour }, "employee_skills names an employee")
    expect(manager.contains { $0.key == orders && $0.isNeighbour }, "orders joins through sales_rep_id: \(manager)")

    let home = SQLDraftRanker.shortlist("name", in: catalog, defaultSchema: "hr")
    expect(home.isEmpty, "a request of stop words only matches nothing")

    let none = SQLDraftRanker.shortlist("the weather tomorrow in Paris", in: catalog, defaultSchema: "sales")
    expect(none.isEmpty, "nothing matches: \(none)")
}

private func testFocusAndReferences() {
    let catalog = fixture()
    let ranked: [SQLDraftRanker.Ranked] = [
        .init(key: customers, score: 20, isNeighbour: false),
        .init(key: orders, score: 10, isNeighbour: false),
        .init(key: products, score: 9, isNeighbour: false),
        .init(key: countries, score: 10, isNeighbour: true),
    ]
    expectEqual(SQLDraftRanker.focus(ranked), [customers, orders],
                "hits with half the best score; neighbours never")
    expectEqual(SQLDraftRanker.withReferences([employeeSkills], in: catalog), [employeeSkills, employees, skills],
                "the tables a focus table points at")
    expectEqual(SQLDraftRanker.withReferences([customers], in: catalog), [customers, countries],
                "but not the tables that point into it")
}

// MARK: - Prompt

private func testRender() {
    let catalog = fixture()
    let text = SQLDraftPrompt.render([orders], in: catalog, terms: [], otherColumnCap: .max)
    let expected = """
        sales.orders -- one row per customer order
          id bigint PK
          customer_id bigint -> sales.customers.id
          status sales.order_status ('pending','paid','shipped','cancelled')
          placed_at timestamptz
          sales_rep_id int -> hr.employees.id
        """
    expectEqual(text, expected, "one table, every column")

    let quoted = SQLDraftPrompt.render([returns], in: catalog, terms: [], otherColumnCap: .max)
    expect(quoted.hasPrefix("sales.\"ReturnRequests\""), "a mixed-case table keeps its quotes: \(quoted)")
    expect(quoted.contains("\"orderId\" bigint -> sales.orders.id"), "and so does a column: \(quoted)")
}

private func testTrim() {
    let catalog = fixture()
    let trimmed = SQLDraftPrompt.render([products], in: catalog, terms: ["discontinued"], otherColumnCap: 0)
    expect(trimmed.contains("id int PK"), "the key survives: \(trimmed)")
    expect(trimmed.contains("discontinued bool"), "the named column survives: \(trimmed)")
    expect(!trimmed.contains("sku"), "the rest goes: \(trimmed)")
    expect(trimmed.contains("(+3 more)"), "and is counted: \(trimmed)")

    let tiny = SQLDraftPrompt.block([orders, customers, products], in: catalog, request: "orders", budget: 30)
    expectEqual(tiny.tables, [orders], "a tiny budget keeps the first table only")
    let roomy = SQLDraftPrompt.block([orders, customers, products], in: catalog, request: "orders", budget: 10_000)
    expectEqual(roomy.tables, [orders, customers, products], "a roomy budget keeps all")
    expect(!roomy.text.contains("more)"), "and every column")
}

private func testBridges() {
    let catalog = fixture()
    expectEqual(SQLDraftPrompt.withBridges([employees, skills], in: catalog), [employees, skills, employeeSkills],
                "the table between two picks joins them")
    expectEqual(SQLDraftPrompt.withBridges([orders, customers], in: catalog), [orders, customers],
                "linked picks need no bridge")
    expectEqual(SQLDraftPrompt.withBridges([employees, skills, employeeSkills], in: catalog),
                [employees, skills, employeeSkills], "a bridge already picked is not added twice")
    expectEqual(SQLDraftPrompt.withBridges([orders, customers, countries], in: catalog), [orders, customers, countries],
                "a chain is connected: orders and countries need no bridge of their own")
    expectEqual(SQLDraftPrompt.components([orders, countries, skills], in: catalog).count, 3,
                "three tables with no key among them are three groups")
}

private func testPickList() {
    let catalog = fixture()
    let list = SQLDraftPrompt.pickList([orders, skills], in: catalog)
    expectEqual(list, """
        sales.orders: id, customer_id, status, placed_at, sales_rep_id -- one row per customer order
        hr.skills: id, name
        """, "one line per candidate")
}

// MARK: - What the model sees

/// The strongest statement available about row data: every word in the
/// block and the pick list traces back to a name, a type, an enum label, a
/// comment, or the fixed words of the format. A catalogue has no field that
/// could hold a cell value; if one were ever added and rendered, its word
/// would appear here as unexplained.
private func testPromptsCarryCatalogueOnly() {
    let catalog = fixture()
    var vocabulary: Set<String> = ["pk", "more", "columns", "not", "loaded"]
    func add(_ text: String) {
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
            vocabulary.insert(String(word))
        }
    }
    for table in catalog.tables {
        add(table.key.schema); add(table.key.name); add(table.comment ?? "")
        for column in table.columns {
            add(column.name); add(column.type); add(column.comment ?? "")
            for label in column.enumLabels ?? [] { add(label) }
            if let ref = column.reference { add(ref.table.schema); add(ref.table.name); add(ref.column) }
        }
    }
    let all = catalog.tables.map(\.key)
    let text = SQLDraftPrompt.block(all, in: catalog, request: "", budget: .max).text
        + "\n" + SQLDraftPrompt.pickList(all, in: catalog)
    let unexplained = text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        .map(String.init)
        .filter { !vocabulary.contains($0) }
    expectEqual(unexplained, [], "every word in the prompts comes from the catalogue")
}

// MARK: - Checker

private func problems(_ sql: String, schema: String = "sales") -> [String] {
    SQLDraftChecker.check(sql, in: fixture(), defaultSchema: schema).map(\.description)
}

private func testCheckerAcceptsGoodSQL() {
    let good = [
        "SELECT c.name, count(o.id) FROM sales.customers c JOIN sales.orders o ON o.customer_id = c.id GROUP BY c.name;",
        "SELECT o.* FROM orders o WHERE o.status = 'paid'",
        "SELECT o.id FROM orders o WHERE o.status IN ('paid', 'shipped') AND o.placed_at > now() - interval '7 days'",
        "WITH recent AS (SELECT o.id FROM orders o) SELECT r.id FROM recent r",
        "SELECT t.n FROM (SELECT count(*) AS n FROM orders) t",
        "SELECT sales.orders.id FROM sales.orders",
        "SELECT orders.id FROM sales.orders",
        "SELECT o.status::sales.order_status, pg_catalog.now() FROM orders o",
        "SELECT r.\"orderId\" FROM sales.\"ReturnRequests\" r",
        "SELECT e.first_name, m.first_name AS manager FROM hr.employees e LEFT JOIN hr.employees m ON m.id = e.manager_id ORDER BY manager",
    ]
    for sql in good {
        expectEqual(problems(sql), [], "clean: \(sql)")
    }
}

private func testTablesRead() {
    let catalog = fixture()
    let reads = SQLDraftChecker.tablesRead(
        "WITH r AS (SELECT 1) SELECT o.id FROM orders o JOIN sales.customers c ON c.id = o.customer_id JOIN orders o2 ON o2.id = o.id JOIN nope n ON true, r",
        in: catalog, defaultSchema: "sales")
    expectEqual(reads, [orders, customers], "in order, once each; no CTE, no unknown table")
}

private func testCheckerFindsProblems() {
    let unknownTable = problems("SELECT x.id FROM sales.invoices x")
    expect(unknownTable.contains("Table sales.invoices does not exist."), "unknown table: \(unknownTable)")

    let unknownColumn = problems("SELECT o.total FROM orders o")
    expect(unknownColumn.first?.hasPrefix("Column o.total does not exist; sales.orders has: id, customer_id") == true,
           "unknown column, with the real ones: \(unknownColumn)")

    let badQualifier = problems("SELECT c.name FROM orders o")
    expectEqual(badQualifier, ["c is not a table or alias in the FROM clause; the aliases are: o."],
                "a qualifier with no table names the real ones")

    let wrongTable = problems("SELECT o.id FROM orders o JOIN shipments s ON o.id = o.order_id")
    expectEqual(wrongTable, ["Column o.order_id does not exist; order_id is a column of s."],
                "a column read through the wrong alias names the right one")

    let braces = problems("SELECT o.id FROM orders o WHERE o.status IN {'paid'}")
    expect(braces.contains("PostgreSQL has no { } lists; write IN ('a', 'b')."), "a brace list: \(braces)")

    let unquoted = problems("SELECT r.orderId FROM sales.ReturnRequests r")
    expect(unquoted.contains("ReturnRequests must be written \"ReturnRequests\", with the double quotes."),
           "an unquoted mixed-case table: \(unquoted)")
    expect(unquoted.contains("orderId must be written \"orderId\", with the double quotes."),
           "an unquoted mixed-case column: \(unquoted)")

    let badEnum = problems("SELECT o.id FROM orders o WHERE o.status = 'complete'")
    expectEqual(badEnum, ["'complete' is not a value of sales.orders.status; use one of: pending, paid, shipped, cancelled."],
                "an enum value that does not exist")
    let badIn = problems("SELECT o.id FROM orders o WHERE o.status NOT IN ('paid', 'refunded')")
    expectEqual(badIn.count, 1, "one bad value in an IN list: \(badIn)")
}

// MARK: - Fixer

private func fixed(_ sql: String, schema: String = "sales") -> SQLDraftFixer.Outcome {
    SQLDraftFixer.fix(sql, in: fixture(), defaultSchema: schema)
}

private func testFixerJoins() {
    let wrongKey = fixed("SELECT e.first_name FROM hr.employees e JOIN hr.employee_skills es ON e.employee_id = es.employee_id JOIN hr.skills s ON s.id = es.skill_id")
    expectEqual(wrongKey.sql, "SELECT e.first_name FROM hr.employees e JOIN hr.employee_skills es ON es.employee_id = e.id JOIN hr.skills s ON s.id = es.skill_id",
                "a join on a missing column takes the foreign key")
    expectEqual(wrongKey.fixes, ["The join to hr.employee_skills now uses its foreign key."], "and says so")

    let selfJoin = fixed("SELECT e.first_name FROM hr.employees e JOIN hr.employees m ON m.boss = e.id", schema: "hr")
    expectEqual(selfJoin.fixes, [], "a self-join is never guessed")

    let good = fixed("SELECT o.id FROM orders o JOIN customers c ON c.id = o.customer_id")
    expectEqual(good.fixes, [], "a correct statement is not touched")
    expectEqual(good.sql, "SELECT o.id FROM orders o JOIN customers c ON c.id = o.customer_id", "byte for byte")

    let cross = fixed("SELECT o.id FROM sales.orders o JOIN hr.employees e ON e.sales_rep_id = o.sales_rep_id")
    expectEqual(cross.sql, "SELECT o.id FROM sales.orders o JOIN hr.employees e ON o.sales_rep_id = e.id",
                "a key across schemas, pointing from the earlier table")
}

private func testFixerQualifiers() {
    let moved = fixed("SELECT c.status, count(o.id) FROM sales.orders o JOIN sales.customers c ON c.id = o.customer_id GROUP BY c.status")
    expectEqual(moved.sql, "SELECT o.status, count(o.id) FROM sales.orders o JOIN sales.customers c ON c.id = o.customer_id GROUP BY o.status",
                "a column moves to the one alias that has it")
    expectEqual(moved.fixes, ["status is read through o, the table that has it."], "one sentence for both places")

    let ambiguous = fixed("SELECT c.unit_price FROM sales.products p JOIN sales.order_items oi ON oi.product_id = p.id JOIN sales.customers c ON c.id = 1")
    expectEqual(ambiguous.fixes, [], "two tables have unit_price: nothing is guessed")

    let inJoin = fixed("SELECT o.id FROM sales.orders o JOIN sales.shipments s ON o.carrier = 'x'")
    expect(!inJoin.sql.contains("s.carrier = 'x'"), "a qualifier inside ON is left to the join rule: \(inJoin.sql)")
}

private func testFixerQuoting() {
    let quoted = fixed("SELECT r.orderId FROM sales.ReturnRequests r")
    expectEqual(quoted.sql, "SELECT r.\"orderId\" FROM sales.\"ReturnRequests\" r", "mixed-case names get quotes")
    expectEqual(problems(quoted.sql), [], "and then pass the check")
}

func runTests() {
    testShortTypes()
    testQuoting()
    testFactsOverlay()
    testResolve()
    testWords()
    testShortlist()
    testFocusAndReferences()
    testRender()
    testTrim()
    testBridges()
    testPickList()
    testPromptsCarryCatalogueOnly()
    testCheckerAcceptsGoodSQL()
    testCheckerFindsProblems()
    testTablesRead()
    testFixerJoins()
    testFixerQualifiers()
    testFixerQuoting()
    print("\(passes) passed, \(failures) failed")
    if failures > 0 { exit(1) }
}
