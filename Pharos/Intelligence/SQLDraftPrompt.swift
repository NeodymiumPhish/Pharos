import Foundation

/// Every string the drafting model receives, built from a `DraftCatalog`.
///
/// Steps 2–6 of drafting live here as text: the pick list, the schema block
/// (the tables' DDL when it fits, the compact block when it does not), the
/// instructions and the repair prompt. The session code in
/// `SQLDraft.swift` only sends them. Pure Foundation; asserted in
/// `PharosTests/SQLDraftPipelineTests.swift`.
///
/// The instruction strings are English and deliberately not localized: they
/// are read by the model, never shown to the analyst.
enum SQLDraftPrompt {

    // MARK: - Budget

    /// How much table text each kind of request may carry, in estimated
    /// tokens (`estimateTokens`, which counts high).
    ///
    /// Every request is held to a share of the model's window AND to a fixed
    /// ceiling. The share keeps a small model inside its window with room
    /// for the instructions and the answer: 8,192 tokens on the Macs Pharos
    /// is tuned for (AFM 3 Core Advanced, macOS 27), 4,096 on the smaller
    /// on-device model. The ceiling keeps a model with a far larger window —
    /// a hosted one, usually — from being sent more than drafting one query
    /// needs: what is sent is paid for, in time or in money, whether or not
    /// it fits.
    struct Budget: Equatable {
        /// The list of table names the model chooses from. Its names are
        /// sent twice — in the list and in the answer's schema, which holds
        /// the choice to them — so the list gets a fifth of the window.
        let pickList: Int
        /// The DDL in one "which of these tables" request.
        let readBlock: Int
        /// The candidates' DDL that goes to the request that writes the
        /// query as it is, with no reading step to narrow it first. Small
        /// on purpose: a writing request this size is far from any window,
        /// and narrowing it would cost a request to save very little.
        let draftUnread: Int
        /// The DDL in the request that writes the query, at most: what the
        /// reading step kept may be this large.
        let draftDefinitions: Int
        /// The compact block in the request that writes the query, when the
        /// DDL does not fit.
        let draftBlock: Int

        static let pickListCeiling = 2_000
        static let readBlockCeiling = 4_000
        static let draftUnreadCeiling = 2_500
        static let draftCeiling = 6_000

        init(contextSize: Int) {
            pickList = min(Self.pickListCeiling, max(300, contextSize / 5))
            readBlock = min(Self.readBlockCeiling, max(500, contextSize * 2 / 5))
            draftUnread = min(Self.draftUnreadCeiling, max(400, contextSize * 3 / 10))
            // Two thirds of the window at most, so the instructions and a
            // long answer have a third between them whatever the window.
            draftBlock = min(Self.draftCeiling, blockBudget(contextSize: contextSize), max(600, contextSize * 2 / 3))
            draftDefinitions = max(600, draftBlock
                - max(0, estimateTokens(ddlDraftInstructions) - estimateTokens(draftInstructions)))
        }
    }

    /// Tokens the compact step-4 block may use in a window of `contextSize`
    /// when no exact count is available.
    ///
    /// The rest goes to the instructions (~250), the answer's schema (~120),
    /// the request (~60) and the answer itself, whose SQL for a three-table
    /// join with grouping runs to 300–500 tokens.
    static func blockBudget(contextSize: Int) -> Int {
        max(600, contextSize - 1500)
    }

    /// A conservative token estimate: identifiers with underscores split
    /// into more tokens than prose, so three characters a token, not four.
    static func estimateTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    // MARK: - Step 2: pick

    /// Most tables the pick step may choose.
    static let pickLimit = 6

    /// Most column names a pick-list line shows.
    static let pickColumnLimit = 10

    static let pickInstructions = """
        You choose database tables for a PostgreSQL query. Choose every table \
        the query must read, including a table that links two others. \
        Choose at most \(pickLimit). Choose only from the list.
        """

    /// One line per candidate: `sales.orders: id, customer_id, status, …`.
    static func pickList(_ shortlist: [DraftCatalog.TableKey], in catalog: DraftCatalog) -> String {
        pickList(shortlist, in: catalog, detail: .columns)
    }

    /// How much a pick-list line says about its table.
    enum PickDetail: CaseIterable {
        /// `sales.orders: id, customer_id, … -- one row per order`
        case columns
        /// `sales.orders -- one row per order`
        case comment
        /// `sales.orders`
        case name
    }

    static func pickList(_ shortlist: [DraftCatalog.TableKey], in catalog: DraftCatalog, detail: PickDetail) -> String {
        shortlist.compactMap { key -> String? in
            guard let table = catalog.table(key) else { return nil }
            var line = key.description
            if detail == .columns, !table.columns.isEmpty {
                var names = table.columns.prefix(pickColumnLimit).map(\.name)
                if table.columns.count > pickColumnLimit { names.append("…") }
                line += ": " + names.joined(separator: ", ")
            }
            if detail != .name, let comment = table.comment { line += " -- " + comment }
            return line
        }.joined(separator: "\n")
    }

    /// The pick list that fits `budget`: every candidate with its columns
    /// when that fits, then with its comment alone, then by name alone; and
    /// when even the names do not fit, as many of the first names as do.
    /// `shortlist` is best first, so what is cut is what matched least.
    static func pickList(
        _ shortlist: [DraftCatalog.TableKey], in catalog: DraftCatalog, budget: Int,
        estimate: (String) -> Int = estimateTokens
    ) -> (text: String, listed: [DraftCatalog.TableKey]) {
        var listed = shortlist.filter { catalog.table($0) != nil }
        for detail in PickDetail.allCases {
            let text = pickList(listed, in: catalog, detail: detail)
            if estimate(text) <= budget { return (text, listed) }
        }
        // By name alone and still too long: keep the head of the list.
        var kept: [DraftCatalog.TableKey] = []
        var used = 0
        for key in listed {
            let cost = estimate(key.description + "\n")
            if used + cost > budget, !kept.isEmpty { break }
            kept.append(key)
            used += cost
        }
        listed = kept
        return (pickList(listed, in: catalog, detail: .name), listed)
    }

    static func pickPrompt(request: String, list: String) -> String {
        "Tables:\n\(list)\n\nRequest: \(request)"
    }

    // MARK: - Step 3: assemble

    /// `picked`, in order, plus what joins them: when the picked tables fall
    /// into groups with no key between them, the one table with a key into
    /// each of two groups is added. Picks that are already connected get
    /// nothing — every extra table is one more thing for a small model to
    /// misuse.
    static func withBridges(_ picked: [DraftCatalog.TableKey], in catalog: DraftCatalog) -> [DraftCatalog.TableKey] {
        var out = picked
        let maxBridges = 3
        for _ in 0..<maxBridges {
            let groups = components(out, in: catalog)
            guard groups.count > 1 else { break }
            var bridge: DraftCatalog.TableKey?
            search: for (i, a) in groups.enumerated() {
                for b in groups[(i + 1)...] {
                    let nearA = Set(a.flatMap(catalog.neighbours(of:)))
                    let nearB = Set(b.flatMap(catalog.neighbours(of:)))
                    if let shared = nearA.intersection(nearB).subtracting(out).sorted().first {
                        bridge = shared
                        break search
                    }
                }
            }
            guard let bridge else { break }
            out.append(bridge)
        }
        return out
    }

    /// `keys` split into groups joined by keys among themselves.
    static func components(_ keys: [DraftCatalog.TableKey], in catalog: DraftCatalog) -> [[DraftCatalog.TableKey]] {
        var groups: [[DraftCatalog.TableKey]] = []
        var seen = Set<DraftCatalog.TableKey>()
        for start in keys where !seen.contains(start) {
            var group: [DraftCatalog.TableKey] = []
            var stack = [start]
            seen.insert(start)
            while let key = stack.popLast() {
                group.append(key)
                for other in keys where !seen.contains(other) && catalog.isLinked(key, other) {
                    seen.insert(other)
                    stack.append(other)
                }
            }
            groups.append(group)
        }
        return groups
    }

    /// The step-4 schema block for `keys`, trimmed to `budget` tokens.
    ///
    /// Trimming keeps the columns a query is built from — primary keys,
    /// foreign keys, columns the request names — and cuts the rest in
    /// steps. A table that still does not fit is left out, last-ranked
    /// first, but the first table is always kept.
    static func block(
        _ keys: [DraftCatalog.TableKey],
        in catalog: DraftCatalog,
        request: String,
        budget: Int,
        needed: [DraftCatalog.TableKey: [String]] = [:],
        estimate: (String) -> Int = estimateTokens
    ) -> (text: String, tables: [DraftCatalog.TableKey]) {
        let terms = SQLDraftRanker.weightedTerms(request).map(\.word)
        var kept = keys.filter { catalog.table($0) != nil }
        for cap in [Int.max, 14, 9, 5, 0] {
            let text = render(kept, in: catalog, terms: terms, otherColumnCap: cap, needed: needed)
            if estimate(text) <= budget { return (text, kept) }
        }
        while kept.count > 1 {
            kept.removeLast()
            let text = render(kept, in: catalog, terms: terms, otherColumnCap: 0, needed: needed)
            if estimate(text) <= budget { return (text, kept) }
        }
        return (render(kept, in: catalog, terms: terms, otherColumnCap: 0, needed: needed), kept)
    }

    /// One table:
    ///
    ///     sales.orders -- one row per customer order
    ///       id bigint PK
    ///       customer_id bigint -> sales.customers.id
    ///       status sales.order_status ('pending','paid','shipped')
    ///       (+2 more)
    ///
    /// `needed` names, per table, the columns the reading step said the
    /// query needs: they are kept through every trim, as keys are.
    static func render(
        _ keys: [DraftCatalog.TableKey],
        in catalog: DraftCatalog,
        terms: [String],
        otherColumnCap: Int,
        needed: [DraftCatalog.TableKey: [String]] = [:]
    ) -> String {
        var blocks: [String] = []
        for key in keys {
            guard let table = catalog.table(key) else { continue }
            let multiKeys = catalog.links.filter { $0.from == key && $0.fromColumns.count > 1 }
            let keyColumns = Set(multiKeys.flatMap(\.fromColumns)).union(needed[key] ?? [])

            var others = 0
            var shown: [DraftCatalog.Column] = []
            for column in table.columns {
                let essential = column.isPrimaryKey || column.reference != nil || keyColumns.contains(column.name)
                    || SQLDraftRanker.nameWords(column.name).contains { word in
                        terms.contains { SQLDraftRanker.similarity($0, word) > 0 }
                    }
                if essential {
                    shown.append(column)
                } else if others < otherColumnCap {
                    shown.append(column)
                    others += 1
                }
            }

            var lines = [key.sql + (table.comment.map { " -- " + $0 } ?? "")]
            if table.columns.isEmpty { lines.append("  (columns not loaded)") }
            for column in shown { lines.append("  " + line(for: column)) }
            let hidden = table.columns.count - shown.count
            if hidden > 0 { lines.append("  (+\(hidden) more)") }
            for link in multiKeys {
                lines.append("  (" + link.fromColumns.map(DraftCatalog.quoted).joined(separator: ", ") + ") -> "
                    + link.to.sql + " (" + link.toColumns.map(DraftCatalog.quoted).joined(separator: ", ") + ")")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n")
    }

    static func line(for column: DraftCatalog.Column) -> String {
        var text = DraftCatalog.quoted(column.name) + " " + column.type
        if column.isPrimaryKey { text += " PK" }
        if let ref = column.reference {
            text += " -> " + ref.table.sql + "." + DraftCatalog.quoted(ref.column)
        }
        // In SQL's own literal form: the model copies this notation into its
        // answer, and `{'a','b'}` copied into an IN list is a syntax error
        // where `('a','b')` is not.
        if let labels = column.enumLabels, !labels.isEmpty {
            text += " (" + labels.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",") + ")"
        }
        if let comment = column.comment { text += " -- " + comment }
        return text
    }

    // MARK: - Step 4: draft

    /// Appended after `IntelligenceInstructions.sqlSafety`.
    ///
    /// Rules first, then three short examples ("Prompting an on-device
    /// foundation model": 2–15 examples, each as simple as possible). Lessons
    /// from `scripts/eval-sql-draft.sh` on the macOS 27 model:
    /// - A concrete sample in a rule is copied into the answer: "now() -
    ///   interval '7 days' style" put a 7-day filter on requests that never
    ///   mentioned time, and "only the values listed in {}" put every enum
    ///   value into an IN list. Rules say what to do; examples show values.
    /// - Enum values were first listed as `{a,b}`, and the model wrote
    ///   `IN {'a', 'b'}`; they are now listed as SQL literals.
    /// - "Filter only on what the request asks for" is there for the same
    ///   reason.
    /// - Without an example of an alias, it invents ones like
    ///   `sales_products` from `sales.products`.
    /// - Without the link-table example, it filters `skill_id = 4` rather
    ///   than joining the table that holds the name.
    /// - It joins tables the request does not need, and an inner join on a
    ///   nullable key drops rows. "Join only the tables the request needs"
    ///   was tried and made it worse (17 → 14 of 22): it dropped needed
    ///   joins too. Not solved here; the analyst reads the draft.
    static let draftInstructions = """
        Write one PostgreSQL SELECT statement for the analyst's request. \
        Use only the listed tables and columns. Give each table a short alias \
        and qualify every column with it. Join tables on the listed -> keys. \
        Filter only on what the request asks for. To filter by a name kept in \
        another table, join that table. Put every selected column that is not \
        in an aggregate in GROUP BY. A column listed with values in () accepts \
        only those values. Keep the double quotes on names listed with them. If the tables \
        cannot answer the request, write the closest query and say what is \
        missing in the note.

        Example 1.
        Tables:
        shop.orders
          id bigint PK
          customer_id bigint -> shop.customers.id
          amount numeric
        shop.customers
          id bigint PK
          name text
        Request: amount spent per customer, highest first
        SQL: SELECT c.name, sum(o.amount) AS spent FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id GROUP BY c.name ORDER BY spent DESC;

        Example 2.
        Tables:
        lib.books
          id int PK
          title text
        lib.book_authors
          book_id int PK -> lib.books.id
          author_id int PK -> lib.authors.id
        lib.authors
          id int PK
          name text
        Request: books by Ursula Le Guin
        SQL: SELECT b.title FROM lib.books b JOIN lib.book_authors ba ON ba.book_id = b.id JOIN lib.authors a ON a.id = ba.author_id WHERE a.name ILIKE '%Ursula Le Guin%';

        Example 3.
        Tables:
        shop.orders
          id bigint PK
          status shop.order_status ('open','paid','void')
          placed_at timestamptz
        Request: paid orders this month
        SQL: SELECT o.id, o.placed_at FROM shop.orders o WHERE o.status = 'paid' AND o.placed_at >= date_trunc('month', now());
        """

    static func draftPrompt(request: String, block: String) -> String {
        "Tables:\n\(block)\n\nRequest: \(request)"
    }

    // MARK: - Step 4, with the tables' DDL

    /// `keys` without the tables that are partitions of another: the parent's
    /// definition, with its `PARTITION BY`, is what the model is shown.
    static func ddlKeys(_ keys: [DraftCatalog.TableKey], in catalog: DraftCatalog) -> [DraftCatalog.TableKey] {
        var seen = Set<DraftCatalog.TableKey>()
        return keys.filter { catalog.table($0) != nil && !catalog.partitions.contains($0) && seen.insert($0).inserted }
    }

    /// The schema block as `CREATE TABLE` statements: each table of `keys`
    /// that has a definition, in order, followed by what DDL does not say —
    /// the table's comment, each enum column's values and each column's
    /// comment — as `--` lines.
    ///
    ///     CREATE TABLE "sales"."orders" (
    ///         "id" bigint NOT NULL,
    ///         "status" sales.order_status,
    ///         CONSTRAINT "orders_pkey" PRIMARY KEY (id)
    ///     ) PARTITION BY RANGE (placed_at);
    ///     -- sales.orders: one row per customer order
    ///     -- status is one of ('pending','paid','shipped')
    static func ddlBlock(
        _ keys: [DraftCatalog.TableKey],
        definitions: [DraftCatalog.TableKey: String],
        in catalog: DraftCatalog
    ) -> (text: String, tables: [DraftCatalog.TableKey]) {
        var blocks: [String] = []
        var tables: [DraftCatalog.TableKey] = []
        for key in ddlKeys(keys, in: catalog) {
            guard let table = catalog.table(key),
                  let ddl = definitions[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !ddl.isEmpty else { continue }
            blocks.append(([ddl] + ddlNotes(for: table)).joined(separator: "\n"))
            tables.append(key)
        }
        return (blocks.joined(separator: "\n\n"), tables)
    }

    /// What a table's DDL leaves out and a draft is better for knowing.
    static func ddlNotes(for table: DraftCatalog.Table) -> [String] {
        var notes: [String] = []
        if let comment = table.comment { notes.append("-- \(table.key.description): \(comment)") }
        for column in table.columns {
            // In SQL's own literal form, as in the compact block: the model
            // copies this notation into its answer.
            if let labels = column.enumLabels, !labels.isEmpty {
                let values = labels.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
                notes.append("-- \(column.name) is one of (\(values))")
            }
            if let comment = column.comment { notes.append("-- \(column.name): \(comment)") }
        }
        return notes
    }

    /// The draft instructions for a block of DDL. Appended after
    /// `IntelligenceInstructions.sqlSafety`.
    ///
    /// They began as `draftInstructions` said about `CREATE TABLE`
    /// statements, with the same three examples, and were then tuned for the
    /// on-device model of the Macs Pharos is used on (AFM 3 Core Advanced,
    /// `scripts/eval-sql-draft.sh`, 2026-11-13). What the tuning found:
    /// - "Put every selected column that is not in an aggregate in GROUP BY"
    ///   put a GROUP BY on statements with no aggregate at all: 10 of 22
    ///   drafts. Saying when to use it, before saying what goes in it, left 2.
    /// - A note that a column "accepts only" its values was read as an
    ///   instruction to filter on them, as the `{}` wording once was: the
    ///   note now says the column "is one of" them, and the rule says when
    ///   to compare.
    /// - The model stops writing at a double quote: a statement that named
    ///   a mixed-case table ended at `SELECT sales.`. It is asked for names
    ///   without quotes; `SQLDraftFixer` adds the quotes a name needs.
    /// - The tables shown are the candidates, which is more than the
    ///   request needs, and the model joined the spare ones on columns that
    ///   do not exist. Saying that more are listed than are needed stopped
    ///   that in two drafts and lost a needed join in a third; with the
    ///   fourth example, which shows NOT EXISTS, the set went from 13
    ///   passes to 15. (14 since the checker stopped reading an alias
    ///   reused in a subquery as the outer table's: that false alarm had
    ///   been sending one draft to a repair which happened to fix it.)
    /// - The same rules put into `draftInstructions` scored WORSE there (13
    ///   passes to 11, 15 runnable to 13), so the compact block keeps the
    ///   wording it was measured with.
    /// On 22 requests a difference of one or two is noise; the count of
    /// GROUP BYs with no aggregate is not.
    ///
    /// The examples keep their bare names in the SQL although the DDL quotes
    /// every name.
    static let ddlDraftInstructions = """
        Write one PostgreSQL SELECT statement for the analyst's request. The \
        tables are given as CREATE TABLE statements; a line that starts with \
        -- is a note about the table above it. More tables are listed than \
        the request needs: use the ones it is about and leave the rest out. \
        Use only the columns a table lists. Give each table a short alias and \
        qualify every column with it. Join tables on their FOREIGN KEY ... \
        REFERENCES constraints. Select the columns the request asks to see. \
        Filter only on what the request asks for. To show or filter by a name \
        kept in another table, join that table. Use GROUP BY only together \
        with an aggregate function; then put every other selected column in \
        it. A note that a column is one of a list of values shows how its \
        values are spelled; compare the column with one of them only when the \
        request asks for it. Write table and column names without double \
        quotes. Read a table declared PARTITION BY by its own name; its \
        partitions are not listed. If the tables cannot answer the request, \
        write the closest query and say what is missing in the note.

        Example 1.
        Tables:
        CREATE TABLE "shop"."orders" (
            "id" bigint NOT NULL,
            "customer_id" bigint,
            "amount" numeric,
            CONSTRAINT "orders_pkey" PRIMARY KEY (id),
            CONSTRAINT "orders_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES shop.customers(id)
        );

        CREATE TABLE "shop"."customers" (
            "id" bigint NOT NULL,
            "name" text,
            CONSTRAINT "customers_pkey" PRIMARY KEY (id)
        );
        Request: amount spent per customer, highest first
        SQL: SELECT c.name, sum(o.amount) AS spent FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id GROUP BY c.name ORDER BY spent DESC;

        Example 2.
        Tables:
        CREATE TABLE "lib"."books" (
            "id" integer NOT NULL,
            "title" text,
            CONSTRAINT "books_pkey" PRIMARY KEY (id)
        );

        CREATE TABLE "lib"."book_authors" (
            "book_id" integer NOT NULL,
            "author_id" integer NOT NULL,
            CONSTRAINT "book_authors_pkey" PRIMARY KEY (book_id, author_id),
            CONSTRAINT "book_authors_book_id_fkey" FOREIGN KEY (book_id) REFERENCES lib.books(id),
            CONSTRAINT "book_authors_author_id_fkey" FOREIGN KEY (author_id) REFERENCES lib.authors(id)
        );

        CREATE TABLE "lib"."authors" (
            "id" integer NOT NULL,
            "name" text,
            CONSTRAINT "authors_pkey" PRIMARY KEY (id)
        );
        Request: books by Ursula Le Guin
        SQL: SELECT b.title FROM lib.books b JOIN lib.book_authors ba ON ba.book_id = b.id JOIN lib.authors a ON a.id = ba.author_id WHERE a.name ILIKE '%Ursula Le Guin%';

        Example 3.
        Tables:
        CREATE TABLE "shop"."orders" (
            "id" bigint NOT NULL,
            "status" shop.order_status,
            "placed_at" timestamp with time zone,
            CONSTRAINT "orders_pkey" PRIMARY KEY (id, placed_at)
        ) PARTITION BY RANGE (placed_at);
        -- status is one of ('open','paid','void')
        Request: paid orders this month
        SQL: SELECT o.id, o.placed_at FROM shop.orders o WHERE o.status = 'paid' AND o.placed_at >= date_trunc('month', now());

        Example 4.
        Tables:
        CREATE TABLE "lib"."authors" (
            "id" integer NOT NULL,
            "name" text,
            CONSTRAINT "authors_pkey" PRIMARY KEY (id)
        );

        CREATE TABLE "lib"."book_authors" (
            "book_id" integer NOT NULL,
            "author_id" integer NOT NULL,
            CONSTRAINT "book_authors_pkey" PRIMARY KEY (book_id, author_id),
            CONSTRAINT "book_authors_author_id_fkey" FOREIGN KEY (author_id) REFERENCES lib.authors(id)
        );
        Request: authors who have no books
        SQL: SELECT a.name FROM lib.authors a WHERE NOT EXISTS (SELECT 1 FROM lib.book_authors ba WHERE ba.author_id = a.id);
        """

    // MARK: - Step 3: read

    /// Appended after `IntelligenceInstructions.sqlSafety`.
    ///
    /// The model is asked for the columns as well as the tables: a table it
    /// can name no column of is one the query does not need, and the columns
    /// are what the draft step is shown when the whole DDL will not fit.
    static let readInstructions = """
        You decide which tables a PostgreSQL query needs. The tables are \
        given as CREATE TABLE statements; a line that starts with -- is a \
        note about the table above it. For the analyst's request, list each \
        table the query must read and, for each, the columns it needs: the \
        columns to show, filter, group, sort or join on. Include a table that \
        links two listed tables. Leave out a table the request does not \
        need. If none of the tables holds what the request asks for, list none.
        """

    static func readPrompt(request: String, block: String) -> String {
        "Tables:\n\(block)\n\nRequest: \(request)"
    }

    /// `keys` split into requests, each holding as many tables' DDL as fit
    /// `budget`, in order. A table with no DDL to show, one whose DDL alone
    /// is over the budget, and every table once `limit` requests are full,
    /// is in `unread`: the model is not asked about it.
    ///
    /// One request when everything fits, which is the usual case; the split
    /// exists so that wide tables cost more requests, never a longer one.
    static func readPacks(
        _ keys: [DraftCatalog.TableKey],
        definitions: [DraftCatalog.TableKey: String],
        in catalog: DraftCatalog,
        budget: Int,
        limit: Int,
        estimate: (String) -> Int = estimateTokens
    ) -> (packs: [[DraftCatalog.TableKey]], unread: [DraftCatalog.TableKey]) {
        var packs: [[DraftCatalog.TableKey]] = []
        var unread: [DraftCatalog.TableKey] = []
        var used = 0
        var seen = Set<DraftCatalog.TableKey>()
        for key in keys where catalog.table(key) != nil && seen.insert(key).inserted {
            // Empty for a partition and for a table with no definition.
            let text = ddlBlock([key], definitions: definitions, in: catalog).text
            let cost = estimate(text) + 1
            guard !text.isEmpty, cost <= budget else {
                unread.append(key)
                continue
            }
            if let last = packs.indices.last, used + cost <= budget {
                packs[last].append(key)
                used += cost
            } else if packs.count < limit {
                packs.append([key])
                used = cost
            } else {
                unread.append(key)
            }
        }
        return (packs, unread)
    }

    /// The names in `named` that are columns of `table`, as the catalogue
    /// spells them. The model writes `"orderId"`, `OrderID` and
    /// `orders.orderid` for the same column.
    static func columns(_ named: [String], of table: DraftCatalog.Table) -> [String] {
        var out: [String] = []
        for raw in named {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
            name = name.replacingOccurrences(of: "\"", with: "").lowercased()
            if let column = table.columns.first(where: { $0.name.lowercased() == name }), !out.contains(column.name) {
                out.append(column.name)
            }
        }
        return out
    }

    // MARK: - Step 6: repair

    static func repairPrompt(request: String, block: String, sql: String, problems: [String]) -> String {
        """
        Tables:
        \(block)

        Request: \(request)

        This draft has errors:
        \(sql)

        Errors:
        \(problems.map { "- " + $0 }.joined(separator: "\n"))

        Write the corrected statement.
        """
    }
}
