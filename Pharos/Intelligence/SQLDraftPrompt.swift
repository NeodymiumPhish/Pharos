import Foundation

/// Every string the drafting model receives, built from a `DraftCatalog`.
///
/// Steps 2–6 of drafting live here as text: the pick list, the compact
/// schema block, the instructions and the repair prompt. The session code in
/// `SQLDraft.swift` only sends them. Pure Foundation; asserted in
/// `PharosTests/SQLDraftPipelineTests.swift`.
///
/// The instruction strings are English and deliberately not localized: they
/// are read by the model, never shown to the analyst.
enum SQLDraftPrompt {

    // MARK: - Budget

    /// Tokens the step-4 block may use when no exact count is available.
    ///
    /// The window is 4096 on every Mac measured (TN3193; `contextSize` on an
    /// M1 Pro, macOS 27). The rest goes to the instructions (~250), the
    /// answer's schema (~120), the request (~60) and the answer itself, whose
    /// SQL for a three-table join with grouping runs to 300–500 tokens.
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
        shortlist.compactMap { key -> String? in
            guard let table = catalog.table(key) else { return nil }
            var names = table.columns.prefix(pickColumnLimit).map(\.name)
            if table.columns.count > pickColumnLimit { names.append("…") }
            var line = key.description + ": " + names.joined(separator: ", ")
            if let comment = table.comment { line += " -- " + comment }
            return line
        }.joined(separator: "\n")
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
        estimate: (String) -> Int = estimateTokens
    ) -> (text: String, tables: [DraftCatalog.TableKey]) {
        let terms = SQLDraftRanker.weightedTerms(request).map(\.word)
        var kept = keys.filter { catalog.table($0) != nil }
        for cap in [Int.max, 14, 9, 5, 0] {
            let text = render(kept, in: catalog, terms: terms, otherColumnCap: cap)
            if estimate(text) <= budget { return (text, kept) }
        }
        while kept.count > 1 {
            kept.removeLast()
            let text = render(kept, in: catalog, terms: terms, otherColumnCap: 0)
            if estimate(text) <= budget { return (text, kept) }
        }
        return (render(kept, in: catalog, terms: terms, otherColumnCap: 0), kept)
    }

    /// One table:
    ///
    ///     sales.orders -- one row per customer order
    ///       id bigint PK
    ///       customer_id bigint -> sales.customers.id
    ///       status sales.order_status ('pending','paid','shipped')
    ///       (+2 more)
    static func render(
        _ keys: [DraftCatalog.TableKey],
        in catalog: DraftCatalog,
        terms: [String],
        otherColumnCap: Int
    ) -> String {
        var blocks: [String] = []
        for key in keys {
            guard let table = catalog.table(key) else { continue }
            let multiKeys = catalog.links.filter { $0.from == key && $0.fromColumns.count > 1 }
            let keyColumns = Set(multiKeys.flatMap(\.fromColumns))

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
