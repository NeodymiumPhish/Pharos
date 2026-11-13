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
    expectEqual(catalog.resolve(schema: "mydb.sales", table: "orders", searchPath: [])?.key, orders,
                "db.schema.table: the schema's last part when the catalog has no dotted schema")
    expect(catalog.resolve(schema: "mydb.hr", table: "orders", searchPath: []) == nil, "the last part must still match")
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

// MARK: - The tables' DDL

private let ordersDDL = """
    CREATE TABLE "sales"."orders" (
        "id" bigint NOT NULL,
        "status" sales.order_status DEFAULT 'pending'::sales.order_status,
        CONSTRAINT "orders_pkey" PRIMARY KEY (id, placed_at)
    ) PARTITION BY RANGE (placed_at);
    """

private func testDDLBlock() {
    var catalog = fixture()
    let partition = Key(schema: "sales", name: "shipments")
    catalog.partitions = [partition]

    expectEqual(SQLDraftPrompt.ddlKeys([orders, partition, orders, Key(schema: "sales", name: "nope"), customers], in: catalog),
                [orders, customers], "DDL keys: no partition, no unknown table, no table twice")

    let customersDDL = "CREATE TABLE \"sales\".\"customers\" (\n    \"id\" bigint NOT NULL\n);\n"
    let block = SQLDraftPrompt.ddlBlock(
        [orders, partition, customers, items],
        definitions: [orders: ordersDDL, customers: customersDDL,
                      partition: "CREATE TABLE \"sales\".\"shipments\" ();\n\nALTER TABLE \"sales\".\"orders\" ATTACH PARTITION \"sales\".\"shipments\"\n    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');"],
        in: catalog)
    let expected = ordersDDL + """

        -- sales.orders: one row per customer order
        -- status is one of ('pending','paid','shipped','cancelled')

        CREATE TABLE "sales"."customers" (
            "id" bigint NOT NULL
        );
        """
    expectEqual(block.text, expected, "DDL block: the definition as given, then what DDL does not say")
    expectEqual(block.tables, [orders, customers], "DDL block: a table with no definition is left out, and so is a partition")
    expect(!block.text.contains("ATTACH PARTITION") && !block.text.contains("2024-01-01"),
           "DDL block: a partition's bounds never reach the prompt")
    expect(block.text.contains("PARTITION BY RANGE (placed_at)"), "DDL block: the parent keeps its PARTITION BY")

    expectEqual(SQLDraftPrompt.ddlNotes(for: catalog.table(items)!), ["-- unit_price: price at time of sale"],
                "DDL notes: a column comment")
    expectEqual(SQLDraftPrompt.ddlNotes(for: catalog.table(customers)!), [], "DDL notes: none for a plain table")

    expect(SQLDraftPrompt.ddlDraftInstructions.contains("PARTITION BY")
           && SQLDraftPrompt.ddlDraftInstructions.contains("FOREIGN KEY"),
           "DDL instructions: say how to read keys and a partitioned table")
}

// MARK: - Budgets and the steps' requests

private func testBudget() {
    let advanced = SQLDraftPrompt.Budget(contextSize: 8192)
    let core = SQLDraftPrompt.Budget(contextSize: 4096)
    let hosted = SQLDraftPrompt.Budget(contextSize: 200_000)

    expectEqual(advanced.pickList, 1638, "8k: the name list gets a fifth of the window")
    expectEqual(advanced.readBlock, 3276, "8k: a read request's DDL gets two fifths")
    expectEqual(advanced.draftUnread, 2457, "8k: three tenths of the window goes to the draft unread")
    expect(core.draftUnread < core.draftDefinitions && advanced.draftUnread < advanced.draftDefinitions,
           "what goes unread is less than what may go at all")
    expectEqual(hosted.draftUnread, SQLDraftPrompt.Budget.draftUnreadCeiling, "hosted: and stops at its ceiling")
    expectEqual(advanced.draftBlock, 5461, "8k: the draft's tables get two thirds of the window")
    expect(advanced.draftDefinitions < advanced.draftBlock && advanced.draftDefinitions > 4500,
           "8k: the DDL gets the block's room less its longer instructions: \(advanced.draftDefinitions)")

    expectEqual(core.draftBlock, 2596, "4k: the compact block's budget is what it was")
    expect(core.draftDefinitions < core.draftBlock && core.draftDefinitions >= 600, "4k: DDL gets less: \(core.draftDefinitions)")
    expect(core.pickList < advanced.pickList && core.readBlock < advanced.readBlock, "4k: every share is smaller")

    // A window fifty times larger is sent no more than the ceilings.
    expectEqual(hosted.pickList, SQLDraftPrompt.Budget.pickListCeiling, "hosted: the name list stops at its ceiling")
    expectEqual(hosted.readBlock, SQLDraftPrompt.Budget.readBlockCeiling, "hosted: a read request stops at its ceiling")
    expectEqual(hosted.draftBlock, SQLDraftPrompt.Budget.draftCeiling, "hosted: the draft's tables stop at the ceiling")
    expect(hosted.draftDefinitions <= SQLDraftPrompt.Budget.draftCeiling && hosted.draftDefinitions > 5000,
           "hosted: and so does their DDL: \(hosted.draftDefinitions)")

    // No request can reach its window: the largest table text, the
    // instructions that go with it and the room kept for the answer.
    for budget in [(4096, core), (8192, advanced)] {
        let read = budget.1.readBlock + SQLDraftPrompt.estimateTokens(SQLDraftPrompt.readInstructions) + 700
        expect(read < budget.0, "\(budget.0): a full read request leaves room: \(read)")
        let pick = 2 * budget.1.pickList + SQLDraftPrompt.estimateTokens(SQLDraftPrompt.pickInstructions) + 400
        expect(pick < budget.0, "\(budget.0): a full name list, sent twice, leaves room: \(pick)")
        let draft = budget.1.draftDefinitions + SQLDraftPrompt.estimateTokens(SQLDraftPrompt.ddlDraftInstructions) + 700
        expect(draft <= budget.0, "\(budget.0): a full DDL draft request leaves room: \(draft)")
    }
}

private func testPickListToBudget() {
    let catalog = fixture()
    let all = [orders, customers, items, products, shipments, returns]

    let roomy = SQLDraftPrompt.pickList(all, in: catalog, budget: 10_000)
    expectEqual(roomy.listed, all, "name list: everything listed when it fits")
    expect(roomy.text.contains("sales.orders: id, customer_id"), "name list: with columns when they fit")

    let columns = SQLDraftPrompt.estimateTokens(roomy.text)
    let tighter = SQLDraftPrompt.pickList(all, in: catalog, budget: columns - 1)
    expectEqual(tighter.listed, all, "name list: still every table one step down")
    expect(!tighter.text.contains("customer_id") && tighter.text.contains("sales.orders -- one row per customer order"),
           "name list: the columns go first, the comment stays: \(tighter.text)")

    let comment = SQLDraftPrompt.estimateTokens(tighter.text)
    let names = SQLDraftPrompt.pickList(all, in: catalog, budget: comment - 1)
    expectEqual(names.text.split(separator: "\n").first.map(String.init), "sales.orders", "name list: then names alone")
    expectEqual(names.listed, all, "name list: still every table")

    let tiny = SQLDraftPrompt.pickList(all, in: catalog, budget: 14)
    expectEqual(tiny.listed, [orders, customers], "name list: too many names keeps the best first: \(tiny.listed)")
    expect(SQLDraftPrompt.estimateTokens(tiny.text) <= 14, "name list: and is inside the budget")
    expectEqual(SQLDraftPrompt.pickList(all, in: catalog, budget: 1).listed, [orders], "name list: never empty")
}

private func testReadPacks() {
    var catalog = fixture()
    catalog.partitions = [shipments]
    func ddl(_ key: Key, columns: Int) -> String {
        "CREATE TABLE \(key.sql) (\n" + (0..<columns).map { "    \"column_\($0)\" bigint" }.joined(separator: ",\n") + "\n);"
    }
    let definitions: [Key: String] = [
        orders: ddl(orders, columns: 6), customers: ddl(customers, columns: 6), items: ddl(items, columns: 6),
        products: ddl(products, columns: 200), shipments: ddl(shipments, columns: 2),
    ]
    let one = SQLDraftPrompt.estimateTokens(SQLDraftPrompt.ddlBlock([orders], definitions: definitions, in: catalog).text)

    let together = SQLDraftPrompt.readPacks([orders, customers, items], definitions: definitions, in: catalog,
                                            budget: 10 * one, limit: 3)
    expectEqual(together.packs, [[orders, customers, items]], "read: one request when everything fits")
    expectEqual(together.unread, [], "read: and nothing left unread")

    let split = SQLDraftPrompt.readPacks([orders, customers, items], definitions: definitions, in: catalog,
                                         budget: 2 * one + 10, limit: 3)
    expectEqual(split.packs, [[orders, customers], [items]], "read: a second request rather than a longer one")
    for pack in split.packs {
        let text = SQLDraftPrompt.ddlBlock(pack, definitions: definitions, in: catalog).text
        expect(SQLDraftPrompt.estimateTokens(text) <= 2 * one + 10, "read: each request is inside the budget")
    }

    let capped = SQLDraftPrompt.readPacks([orders, customers, items], definitions: definitions, in: catalog,
                                          budget: one + 2, limit: 2)
    expectEqual(capped.packs, [[orders], [customers]], "read: no more requests than the limit")
    expectEqual(capped.unread, [items], "read: what is over the limit is not asked about")

    let mixed = SQLDraftPrompt.readPacks([orders, products, shipments, returns, orders], definitions: definitions,
                                         in: catalog, budget: 4 * one, limit: 3)
    expectEqual(mixed.packs, [[orders]], "read: a table is asked about once")
    expectEqual(mixed.unread, [products, shipments, returns],
                "read: too wide, a partition, and with no DDL are kept without being asked about")
}

private func testReadAnswerColumns() {
    let catalog = fixture()
    let table = catalog.table(returns)!
    expectEqual(SQLDraftPrompt.columns(["\"orderId\"", "REQUESTEDAT", "ReturnRequests.id", "nope", "orderid"], of: table),
                ["orderId", "requestedAt", "id"], "read answer: columns as the catalogue spells them, once each, real ones only")

    // A column the reading step named survives the hardest trim.
    let needed = SQLDraftPrompt.render([products], in: catalog, terms: [], otherColumnCap: 0, needed: [products: ["sku"]])
    expect(needed.contains("sku text") && !needed.contains("discontinued"), "needed columns are kept: \(needed)")
    let block = SQLDraftPrompt.block([products, customers], in: catalog, request: "", budget: 40,
                                     needed: [products: ["sku"], customers: ["name"]])
    expect(block.text.contains("sku text"), "and kept through the block's trimming: \(block.text)")
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

// MARK: - Which query a table belongs to

private func lexed(_ sql: String) -> [SQLStatementScope.Token] {
    let snapshot = SQLLexSnapshot.shared(for: sql)
    return SQLStatementScope.tokens(in: snapshot, range: NSRange(location: 0, length: snapshot.length))
}

/// The index of the `nth` token spelled `text`.
private func index(of text: String, nth: Int = 0, in tokens: [SQLStatementScope.Token]) -> Int {
    tokens.indices.filter { tokens[$0].text == text }[nth]
}

private func testQueriesOfAStatement() {
    // A subquery sees the tables around it; they do not see its own.
    let nested = lexed("SELECT c.name FROM sales.customers c WHERE c.id IN (SELECT o.customer_id FROM sales.orders o WHERE count(o.id) > (1 + 2))")
    let queries = SQLDraftChecker.Queries(nested)
    let references = SQLStatementScope.tableReferences(in: nested)
    expectEqual(references.map { nested[$0.at].text + "." + nested[$0.at + 2].text }, ["sales.customers", "sales.orders"],
                "references: each table with the token it is declared at")
    expectEqual(references.map(\.ref.qualifier), ["c", "o"], "references: in the order they are named")
    let customersAt = references[0].at, ordersAt = references[1].at
    let outerColumn = index(of: "c", nth: 0, in: nested)          // c.name, in the outer SELECT
    let innerColumn = index(of: "o", nth: 0, in: nested)          // o.customer_id, in the subquery
    let deepColumn = index(of: "o", nth: 2, in: nested)           // o.id, inside count( )
    expect(queries.sees(customersAt, from: outerColumn), "queries: a table is seen in its own query")
    expect(queries.sees(customersAt, from: innerColumn), "queries: and in a subquery of it")
    expect(queries.sees(ordersAt, from: innerColumn), "queries: a subquery's table is seen inside the subquery")
    expect(queries.sees(ordersAt, from: deepColumn), "queries: brackets round an expression or a call open no query")
    expect(!queries.sees(ordersAt, from: outerColumn), "queries: a subquery's table is not seen by the query around it")
    expectEqual(Set(queries.query).count, 2, "queries: two in all")

    // The two sides of a UNION are beside each other.
    let union = lexed("SELECT o.id FROM sales.orders o UNION ALL SELECT c.id FROM sales.customers c")
    let sides = SQLDraftChecker.Queries(union)
    let unionRefs = SQLStatementScope.tableReferences(in: union)
    expect(!sides.sees(unionRefs[1].at, from: index(of: "o", in: union)), "queries: the second side's table is not seen by the first")
    expect(!sides.sees(unionRefs[0].at, from: index(of: "c", in: union)), "queries: nor the first side's by the second")
    expect(sides.sees(unionRefs[1].at, from: index(of: "c", in: union)), "queries: each side sees its own")

    // A WITH body and a derived table are queries of their own.
    let with = lexed("WITH recent AS (SELECT o.id FROM sales.orders o) SELECT r.id FROM recent r JOIN (SELECT s.order_id FROM sales.shipments s) d ON d.order_id = r.id")
    let parts = SQLDraftChecker.Queries(with)
    let withRefs = SQLStatementScope.tableReferences(in: with)
    let main = index(of: "r", nth: 0, in: with)
    expectEqual(withRefs.map(\.ref.table), ["orders", "recent", "shipments"], "references: every FROM, wherever it is")
    expect(!parts.sees(withRefs[0].at, from: main), "queries: the main query does not see a WITH body's table")
    expect(parts.sees(withRefs[1].at, from: main), "queries: it sees what it names itself")
    expect(!parts.sees(withRefs[2].at, from: main), "queries: and not a derived table's table")
    expect(!parts.sees(0, from: 999) && !parts.sees(999, from: 0), "queries: a token that is not there is seen by nothing")
}

private func testNoCorrectionThroughATableThatCannotBeNamed() {
    // The column is in a table of the subquery; the query around it cannot
    // read through that table. This used to be "corrected" into
    // `order_items.order_id NOT IN (…)`, which names a table not in FROM.
    let draft = "SELECT c.id, c.name FROM sales.customers c JOIN sales.orders o ON c.id = o.customer_id WHERE o.order_id NOT IN (SELECT order_id FROM sales.order_items)"
    expectEqual(problems(draft), ["Column o.order_id does not exist; sales.orders has: id, customer_id, status, placed_at, sales_rep_id."],
                "subquery: the hint names the table's own columns, not a table out of reach")
    let unchanged = fixed(draft)
    expectEqual(unchanged.sql, draft, "subquery: the column is not moved to a table the outer query cannot name")
    expectEqual(unchanged.fixes, [], "subquery: and no correction is claimed")

    // Inside the subquery the same table CAN be named, and still is.
    let inner = fixed("SELECT c.name FROM sales.customers c WHERE c.id IN (SELECT o.customer_id FROM sales.orders o JOIN sales.order_items oi ON oi.order_id = o.id WHERE o.quantity > 3)")
    expectEqual(inner.sql, "SELECT c.name FROM sales.customers c WHERE c.id IN (SELECT o.customer_id FROM sales.orders o JOIN sales.order_items oi ON oi.order_id = o.id WHERE oi.quantity > 3)",
                "subquery: a column is still moved to the table beside it")

    // A subquery may name the tables around it: a correlated reference.
    let correlated = "SELECT c.id FROM sales.customers c WHERE EXISTS (SELECT 1 FROM sales.orders o WHERE o.customer_id = c.id AND o.signed_up_at > now())"
    expectEqual(problems(correlated), ["Column o.signed_up_at does not exist; signed_up_at is a column of c."],
                "correlated: the outer table is in reach, and the hint says so")
    expectEqual(fixed(correlated).sql,
                "SELECT c.id FROM sales.customers c WHERE EXISTS (SELECT 1 FROM sales.orders o WHERE o.customer_id = c.id AND c.signed_up_at > now())",
                "correlated: a column is moved to an outer table, which the subquery can read")

    // The other side of a UNION is out of reach too.
    let union = "SELECT o.name FROM sales.orders o UNION SELECT c.name FROM sales.customers c"
    expectEqual(fixed(union).sql, union, "union: a column is not moved to the other side's table")
    expect(problems(union).first?.contains("sales.orders has:") == true, "union: and the hint does not name it: \(problems(union))")

    // An outer table whose alias the subquery has taken for another table
    // cannot be named there: `c` inside means orders.
    let shadowed = "SELECT c.id FROM sales.customers c WHERE EXISTS (SELECT 1 FROM sales.orders c WHERE c.name = 'x')"
    expectEqual(fixed(shadowed).fixes, [], "shadowed: no correction through a name that means another table here")
    expectEqual(problems(shadowed), ["Column c.name does not exist; sales.orders has: id, customer_id, status, placed_at, sales_rep_id."],
                "shadowed: the column is checked against the table the alias means in the subquery")
    expectEqual(problems("SELECT c.name FROM sales.customers c WHERE EXISTS (SELECT 1 FROM sales.orders c WHERE c.status = 'paid')"), [],
                "shadowed: and each use of the alias is checked against its own table")

    // The alias hint lists the aliases this place can use.
    let alias = problems("SELECT x.id FROM sales.orders o WHERE o.id IN (SELECT oi.order_id FROM sales.order_items oi)")
    expectEqual(alias, ["x is not a table or alias in the FROM clause; the aliases are: o."],
                "alias hint: a subquery's alias is not offered to the query around it")
}

private func testJoinIsNotRewrittenOntoATableOutOfReach() {
    // The key between employees and employee_skills is real, but
    // employee_skills is inside the derived table: its alias means nothing
    // in this ON. This used to become `ON es.employee_id = e.id`.
    let draft = "SELECT e.first_name FROM (SELECT es.employee_id FROM hr.employee_skills es) x JOIN hr.employees e ON e.employee_id = x.employee_id"
    let outcome = fixed(draft, schema: "hr")
    expectEqual(outcome.sql, draft, "join: not rewritten with an alias from inside a derived table")
    expectEqual(outcome.fixes, [], "join: and no correction is claimed")

    // Beside each other, the key is still used.
    let beside = fixed("SELECT e.first_name FROM hr.employee_skills es JOIN hr.employees e ON e.employee_id = es.employee_id", schema: "hr")
    expectEqual(beside.sql, "SELECT e.first_name FROM hr.employee_skills es JOIN hr.employees e ON es.employee_id = e.id",
                "join: two tables of one query still get their foreign key")

    // The same alias in a later subquery is another table: the ON belongs
    // to the one declared before it.
    let reused = fixed("SELECT e.first_name FROM hr.employee_skills es JOIN hr.employees e ON e.employee_id = es.employee_id WHERE e.id IN (SELECT e.id FROM hr.skills e)", schema: "hr")
    expect(reused.sql.hasPrefix("SELECT e.first_name FROM hr.employee_skills es JOIN hr.employees e ON es.employee_id = e.id WHERE"),
           "join: an alias reused later does not hide the table being joined: \(reused.sql)")
}

/// A table and a column whose names are PostgreSQL key words.
private func reservedCatalog() -> DraftCatalog {
    DraftCatalog(columns: [
        Key(schema: "public", name: "user"): cols([("id", "bigint", true), ("order", "integer", false), ("name", "text", false)]),
        Key(schema: "public", name: "visits"): cols([("id", "bigint", true), ("user_id", "bigint", false)]),
    ], facts: [:])
}

private func testReservedNamesGetQuotes() {
    let catalog = reservedCatalog()
    let draft = "SELECT u.order, u.name FROM public.user u JOIN public.visits v ON v.user_id = u.id ORDER BY u.order"
    let found = SQLDraftChecker.check(draft, in: catalog, defaultSchema: "public").map(\.description)
    expect(found.contains { $0.contains("order must be written \"order\"") }, "reserved: a key word used as a column is reported: \(found)")
    expect(found.contains { $0.contains("user must be written \"user\"") }, "reserved: and one used as a table: \(found)")

    let fixed = SQLDraftFixer.fix(draft, in: catalog, defaultSchema: "public")
    expectEqual(fixed.sql,
                "SELECT u.\"order\", u.name FROM public.\"user\" u JOIN public.visits v ON v.user_id = u.id ORDER BY u.\"order\"",
                "reserved: a key word after a dot gets its quotes; ORDER BY itself does not")
    expectEqual(SQLDraftChecker.check(fixed.sql, in: catalog, defaultSchema: "public").map(\.description), [],
                "reserved: and then passes the check")
    expect(fixed.fixes.contains("order is written with its double quotes."), "reserved: the fix is said: \(fixed.fixes)")

    // Nothing to do where no name is a key word.
    let plain = SQLDraftFixer.fix("SELECT o.id FROM sales.orders o ORDER BY o.id", in: fixture(), defaultSchema: "sales")
    expectEqual(plain.fixes, [], "reserved: an ordinary catalogue is left alone")
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
    testDDLBlock()
    testBudget()
    testPickListToBudget()
    testReadPacks()
    testReadAnswerColumns()
    testCheckerAcceptsGoodSQL()
    testCheckerFindsProblems()
    testTablesRead()
    testFixerJoins()
    testFixerQualifiers()
    testFixerQuoting()
    testReservedNamesGetQuotes()
    testQueriesOfAStatement()
    testNoCorrectionThroughATableThatCannotBeNamed()
    testJoinIsNotRewrittenOntoATableOutOfReach()
    print("\(passes) passed, \(failures) failed")
    if failures > 0 { exit(1) }
}
