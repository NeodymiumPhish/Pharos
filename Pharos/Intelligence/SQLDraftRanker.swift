import Foundation

/// Step 1 of drafting: which tables the request is probably about, found in
/// code before the model is asked anything.
///
/// The on-device model has a 4096-token window. Handing it a whole catalogue
/// and asking it to search — the tool-calling design this replaced — spent
/// the window on table lists and timed out. Matching the request's words to
/// table, column and comment names is crude, but it is free, it is
/// deterministic, and the model only has to choose among (or simply use)
/// what it finds.
///
/// Pure Foundation; asserted in `PharosTests/SQLDraftPipelineTests.swift`.
enum SQLDraftRanker {

    struct Ranked: Equatable {
        let key: DraftCatalog.TableKey
        let score: Double
        /// Reached through a foreign key from a direct hit, not named itself.
        let isNeighbour: Bool
    }

    /// The most tables a shortlist holds.
    static let shortlistLimit = 30

    /// How many of the best direct hits contribute their foreign-key
    /// neighbours.
    static let neighbourSeeds = 5

    // MARK: - Words

    /// Words that say nothing about WHICH table: question words, quantities,
    /// time words a date column answers, and SQL's own vocabulary. Not
    /// `order` or `return`: in a request those are nearly always the thing,
    /// not the clause.
    static let stopWords: Set<String> = [
        "a", "about", "above", "after", "all", "an", "and", "any", "are", "as", "at", "average", "be", "been",
        "before", "below", "between", "biggest", "both", "but", "by", "can", "count", "day", "each", "every",
        "fewer", "find", "first", "for", "from", "get", "give", "greater", "group", "had", "has", "have", "higher", "highest",
        "how", "i", "in", "into", "is", "it", "its", "last", "latest", "least", "less", "list", "lower", "lowest",
        "many", "max", "maximum", "me", "min", "minimum", "month", "more", "most", "much", "my", "name",
        "never", "newest", "no", "not", "number", "of", "oldest", "on", "or", "other", "our",
        "over", "per", "quarter", "query", "recent", "rows", "select", "show", "since", "smallest",
        "so", "some", "still", "sum", "than", "that", "the", "their", "them", "there", "these", "they",
        "this", "those", "to", "today", "top", "total", "under", "was", "week", "were", "what", "when",
        "where", "which", "who", "whose", "with", "within", "without", "year", "yesterday", "you",
    ]

    /// A few everyday words and the names schemas usually use for them.
    /// Weighted below a direct match; a guess, never a rule.
    static let related: [String: [String]] = [
        "revenue": ["price", "amount", "payment", "item"],
        "income": ["price", "amount", "payment"],
        "spend": ["amount", "payment", "order"],
        "spent": ["amount", "payment", "order"],
        "sold": ["order", "item", "quantity"],
        "sell": ["order", "item", "quantity"],
        "sale": ["order", "item"],
        "buy": ["order", "item"],
        "bought": ["order", "item"],
        "purchase": ["order", "item"],
        "stock": ["inventory", "quantity"],
        "client": ["customer"],
        "buyer": ["customer"],
        "staff": ["employee"],
        "worker": ["employee"],
        "employee": ["staff"],
        "boss": ["manager"],
        "rating": ["review"],
        "review": ["rating"],
        "pay": ["payment", "salary"],
        "paid": ["payment"],
        "salary": ["pay", "compensation"],
        "price": ["cost", "amount"],
        "cost": ["price", "amount"],
        "user": ["account", "customer"],
        "account": ["user"],
        "region": ["country"],
        "country": ["region"],
        "city": ["address"],
        "shipped": ["shipment"],
        "ship": ["shipment"],
        "delivered": ["shipment"],
        "deliver": ["shipment"],
        "tracking": ["shipment"],
        "carrier": ["shipment"],
        "item": ["product"],
        "team": ["department"],
        "department": ["team"],
        "hired": ["employee"],
        "hire": ["employee"],
        "refund": ["payment", "return"],
        "refunded": ["payment", "return"],
        "returned": ["return"],
        "promotion": ["promo", "discount", "coupon"],
        "promo": ["promotion", "discount", "coupon"],
        "coupon": ["promotion", "discount"],
        "discount": ["promotion"],
        "warehouse": ["inventory"],
    ]

    /// `orders`, `OrderItems`, `order_items2` → `order`, `item`.
    static func nameWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in name {
            if ch.isLetter {
                if ch.isUppercase, previousWasLower, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(Character(ch.lowercased()))
                previousWasLower = ch.isLowercase
            } else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map(singular)
    }

    /// The request's content words, singular, without stop words.
    static func requestWords(_ request: String) -> [String] {
        var out: [String] = []
        for raw in request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
            var word = String(raw)
            if word.hasSuffix("'s") { word.removeLast(2) }
            word = word.replacingOccurrences(of: "'", with: "")
            guard word.count > 1, !stopWords.contains(word), word.contains(where: \.isLetter) else { continue }
            let s = singular(word)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// A small, predictable singular: enough to meet `orders` with `order`
    /// and `categories` with `category`.
    static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    /// 1 for the same word, 0.6 when one starts the other (`ship` and
    /// `shipment`), else 0. Prefixes shorter than four letters are noise.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4, long.hasPrefix(short) { return 0.6 }
        return 0
    }

    // MARK: - Ranking

    /// Each request word with its weight: 1 for the word, 0.7 for a related
    /// word it brings in.
    static func weightedTerms(_ request: String) -> [(word: String, weight: Double)] {
        var terms: [(String, Double)] = []
        let words = requestWords(request)
        for word in words { terms.append((word, 1)) }
        for word in words {
            for extra in related[word] ?? [] where !terms.contains(where: { $0.0 == extra }) {
                terms.append((extra, 0.7))
            }
        }
        return terms
    }

    /// How well one table matches. A table-name word is worth the most; a
    /// column name says the table HOLDS the thing; a comment is a hint.
    static func score(_ table: DraftCatalog.Table, terms: [(word: String, weight: Double)]) -> Double {
        let tableWords = nameWords(table.key.name)
        let columnWords = table.columns.map { nameWords($0.name) }
        let commentWords = Set((table.comment ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter }).map { singular(String($0)) })

        var total = 0.0
        for (word, weight) in terms {
            let byName = tableWords.map { similarity(word, $0) }.max() ?? 0
            let byColumn = columnWords.map { words in words.map { similarity(word, $0) }.max() ?? 0 }.max() ?? 0
            let byComment: Double = commentWords.contains(word) ? 1 : 0
            total += weight * max(10 * byName, 3 * byColumn, 2 * byComment)
        }
        return total
    }

    /// The shortlist: direct hits by score, then the foreign-key neighbours
    /// of the best few (a join needs the table in the middle even when the
    /// request never names it). The default schema breaks ties.
    ///
    /// Empty when nothing matches at all; the caller decides what that means.
    static func shortlist(
        _ request: String, in catalog: DraftCatalog, defaultSchema: String?
    ) -> [Ranked] {
        let terms = weightedTerms(request)
        guard !terms.isEmpty else { return [] }
        let home = defaultSchema?.lowercased()

        var hits: [Ranked] = []
        for table in catalog.tables {
            var s = score(table, terms: terms)
            guard s > 0 else { continue }
            if table.key.schema.lowercased() == home { s += 0.5 }
            hits.append(Ranked(key: table.key, score: s, isNeighbour: false))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
        hits = Array(hits.prefix(shortlistLimit))

        var seen = Set(hits.map(\.key))
        var neighbours: [Ranked] = []
        for seed in hits.prefix(neighbourSeeds) {
            for key in catalog.neighbours(of: seed.key) where !seen.contains(key) {
                seen.insert(key)
                neighbours.append(Ranked(key: key, score: seed.score * 0.25, isNeighbour: true))
            }
        }
        var all = hits + neighbours
        all.sort { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
        return Array(all.prefix(shortlistLimit))
    }

    /// The share of the best score a direct hit needs to be in focus. Half:
    /// a table-name match scores 10 and a column match 3, so when the
    /// request names a table, the tables that merely share one of its
    /// column names (`customer_id` is everywhere) stay out.
    static let focusShare = 0.5

    /// The direct hits that matter: at least `focusShare` of the best. A
    /// request that names one table strongly and brushes ten others with a
    /// shared column name (`customer_id` is everywhere) focuses on the one.
    static func focus(_ ranked: [Ranked]) -> [DraftCatalog.TableKey] {
        let hits = ranked.filter { !$0.isNeighbour }
        guard let best = hits.map(\.score).max() else { return [] }
        return hits.filter { $0.score >= best * focusShare }.map(\.key)
    }

    /// `keys` plus the tables their foreign keys point AT, in order. A
    /// referenced table is where a name lives (`skill_id` → `skills.name`),
    /// and a request filters by names far more often than by ids. Tables
    /// that point INTO the focus are not added: those are child rows, needed
    /// only when the request names them, and then they are hits already.
    static func withReferences(_ keys: [DraftCatalog.TableKey], in catalog: DraftCatalog) -> [DraftCatalog.TableKey] {
        var out = keys
        for key in keys {
            for link in catalog.links where link.from == key && !out.contains(link.to) {
                out.append(link.to)
            }
        }
        return out
    }
}
