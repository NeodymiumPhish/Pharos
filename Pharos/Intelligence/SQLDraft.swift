import Foundation
import FoundationModels

/// "Describe the query": a sentence in, one `SELECT` out.
///
/// Drafting runs in steps. Each model step is ONE request in a NEW session,
/// with greedy sampling and no tools, so nothing accumulates from step to
/// step: a request holds its instructions, the table text for that step and
/// the analyst's sentence, and no earlier answer. Pharos does the searching
/// and the bookkeeping; the model is asked small questions.
///
/// 1. Find (code): `SQLDraftRanker` matches the request to table, column and
///    comment names. A request that names its tables is settled here, with
///    no request to the model.
/// 2. Choose (model, only when needed): when the words match too many tables
///    or none, the model chooses from a list of table NAMES. Its answer is
///    held to those names, so it cannot invent one.
/// 3. Read (database, then model when needed): Pharos reads the DDL of each
///    candidate — a partition's parent in its place. A set small enough to
///    hand to step 4 as it is goes there. A larger one is put to the model
///    first: which of these tables does the query need, and which of their
///    columns? Its DDL is split over as many requests as keep each inside
///    its budget, and at most `maxReadRequests` in a draft. If no candidate holds what
///    the request asks for, step 2 runs once more over the rest of the
///    names.
/// 4. Write (model): the tables that passed step 3, plus any table that
///    joins two of them, and the request in; `SQLDraft` out. The tables are
///    shown as DDL when that fits and otherwise as a compact block that
///    keeps the keys and the columns step 3 named.
/// 5. Check (code): `SQLDraftChecker` finds names that do not exist, and
///    `SQLDraftFixer` corrects what the catalogue can answer for: a join on
///    the wrong columns, a column read through the wrong alias, a missing
///    pair of quotes.
/// 6. Repair (model, at most once, only for what is left): the draft and its
///    problems in, a corrected draft out.
///
/// Every request's table text is held to `SQLDraftPrompt.Budget`: a share of
/// the model's window and a fixed ceiling, whichever is smaller. A step that
/// would go over is split or made smaller before it is sent, never sent in
/// hope. So a draft costs a few small requests on a model with an 8,192- or
/// 4,096-token window, and the same few small requests on one with a
/// 200,000-token window.
///
/// Nothing here runs SQL: `draft` returns text, `SQLDraftPolicy` reviews it,
/// and the analyst decides. No row can reach a prompt: the table text comes
/// from a `DraftCatalog` or from the tables' DDL, and neither holds one.
///
/// A card that already holds a statement asks for a change to it instead
/// (`draft(_:adjusting:)`): the statement goes into the writing request with
/// the change, its own tables are always among the ones shown, and the steps
/// above only look for tables the change adds. See "Adjusting" below.
///
/// Measured with `scripts/eval-sql-draft.sh` (22 requests, a 26-table
/// fixture); the figures are in docs/apple-intelligence.md.

// MARK: - The answer

@Generable
struct SQLDraft {

    /// First, so the model decides on its tables and joins before it
    /// writes them ("Generating Swift data structures with guided
    /// generation": properties are generated in declaration order).
    @Guide(description: "the tables, joins and filters to use, in one short line")
    var plan: String

    @Guide(description: "one PostgreSQL SELECT statement")
    var sql: String

    /// Generated, never shown. In the evaluation (2026-10-05) about two notes
    /// in three said "the request cannot be answered because …" over a
    /// statement that answered it, so the strip says what the statement
    /// reads instead, which Pharos can tell for certain.
    ///
    /// Kept in the answer because the prompt is measured as a whole: the
    /// note comes after `sql`, but removing the field and its sentence in
    /// the instructions changes the prompt, and that run scored worse
    /// (16 of 22 runnable, about 7 right, against 17 and about 10). With 22
    /// requests the difference may be noise; the better-measured prompt
    /// stays until a larger evaluation says otherwise.
    @Guide(description: "one sentence: what was assumed, or what the tables cannot answer")
    var note: String
}

/// The plan and the note are a line each, and the statement is a statement:
/// one that reaches `statementLimit` is a model repeating itself, not a
/// query drafted from a sentence.
extension SQLDraft: TextLimitedAnswer {
    static let textLimits = [
        "plan": SQLDraftPipeline.lineLimit,
        "sql": SQLDraftPipeline.statementLimit,
        "note": SQLDraftPipeline.lineLimit,
    ]
}

// MARK: - Pipeline

@MainActor
final class SQLDraftPipeline {

    enum Stage: Equatable {
        /// `reading`: fetching the candidates' DDL and asking the model
        /// which of them the query needs.
        case finding, choosing, reading, writing, checking, repairing
    }

    /// Fetches table definitions, as View Table DDL shows them. A table it
    /// cannot read is left out of the answer.
    typealias DefinitionSource = @MainActor ([DraftCatalog.TableKey]) async -> [DraftCatalog.TableKey: DraftCatalog.Definition]

    enum Failure: LocalizedError, Equatable {
        /// No table or column name resembles the request.
        case noMatchingTables
        /// The model answered with no statement.
        case emptyDraft
        /// The statement to change is more than the model can take in and
        /// write out again.
        case statementTooLong
        /// The model answered with the statement it was given.
        case unchanged

        var errorDescription: String? {
            switch self {
            case .noMatchingTables:
                return String(localized: "No table matches that description. Name a table or column, or choose the schema that holds the data.")
            case .emptyDraft:
                return String(localized: "The model could not draft a query. Try describing it another way.")
            case .statementTooLong:
                return String(localized: "This query is too long for the model to change. Select less of it into a card of its own, or use a model with a larger context window.")
            case .unchanged:
                return String(localized: "The model made no change to the query. Try describing the change another way.")
            }
        }
    }

    struct Result {
        let sql: String
        /// The catalogue tables the final statement reads, in order.
        let reads: [DraftCatalog.TableKey]
        /// What the check still finds after the repair; empty when clean.
        let problems: [String]
        /// What `SQLDraftFixer` changed in the model's statement.
        let fixes: [String]
        /// The tables the draft step was shown.
        let tables: [DraftCatalog.TableKey]
        /// How many requests the model was sent.
        let requests: Int
        /// Step by step, for the evaluation harness. Holds table names and
        /// counts, never the request or the SQL, and is never logged.
        let trace: [String]
    }

    /// When step 3 asks the model about the candidates it has read.
    enum ReadPolicy: String {
        /// Only when the candidates' DDL is more than the writing request
        /// takes unread (`Budget.draftUnread`), or one of them has no DDL.
        /// A smaller set goes to the writing step as it is: the model reads
        /// the same DDL there, in one request instead of two.
        case whenLarge
        /// Whenever there is a candidate to ask about.
        case always
    }

    /// `whenLarge`, from the evaluation's figures (22 requests, AFM 3 Core
    /// Advanced, 2026-11-13): asking about every candidate set passed 11
    /// to 12 where this passes 13, with one more request and about two
    /// seconds more for each draft. The reading step earns its request
    /// when it keeps the writing request small, not when that is small
    /// already. A `var` only so that `scripts/eval-sql-draft.sh` can score
    /// the other policy.
    static var readPolicy = ReadPolicy.whenLarge

    /// The most candidates whose DDL is read. More than this and the model
    /// first chooses among their names.
    static let readLimit = 8

    /// The most "which of these tables" requests one draft sends, over both
    /// rounds of step 3. With one request to choose, one to write and one
    /// to repair, a draft is six requests at the very most.
    static let maxReadRequests = 3

    /// Tokens kept free for the answer: plan, statement and note.
    static let answerReserve = 700

    /// The most characters of a field that is asked for as one short line:
    /// a reason, a plan, a note. An endpoint is held to it (`textLimits`).
    nonisolated static let lineLimit = 300

    /// The most characters of a column name in a reading step's answer.
    nonisolated static let nameLimit = 128

    /// The most characters of a drafted statement. A draft from a sentence
    /// is a few hundred. One that is this long was stopped here by an
    /// endpoint, or ran on by itself: either way it is reported as cut off
    /// and goes to the repair step rather than to the analyst as it is.
    nonisolated static let statementLimit = 2_000

    /// What the check says about a statement that reached `statementLimit`.
    /// Read by the analyst under the draft and by the model in the repair
    /// request, so it says what is wrong and nothing to either of them.
    nonisolated static func cutOffProblem(limit: Int = statementLimit) -> String {
        "The statement is \(limit) characters long and was probably cut off."
    }

    private func isCutOff(_ rawSQL: String) -> Bool {
        rawSQL.unicodeScalars.count >= statementLimit
    }

    // MARK: Adjusting

    /// The most of a window the statement being changed may take, as a
    /// divisor: it is sent once and written out once, so a fifth of the
    /// window each way leaves three fifths for the instructions, the tables
    /// and the rest of the answer.
    static let adjustShare = 5

    /// The most estimated tokens of a statement being changed, whatever the
    /// window: about 12,000 characters.
    static let adjustCeiling = 4_000

    /// How much longer than the statement it changes a changed statement
    /// may be, in characters, before it counts as cut off.
    nonisolated static let adjustGrowth = 1_500

    /// The most characters of a statement that can be changed by a model
    /// with a window of `contextSize` tokens.
    static func adjustLimit(contextSize: Int) -> Int {
        min(adjustCeiling, contextSize / adjustShare) * 3
    }

    /// The statement being changed, cleaned; nil when drafting from a
    /// sentence alone.
    private var base: String?
    /// What the check says about `base` itself. The analyst wrote those
    /// names: they are not the model's mistakes, and are neither repaired
    /// nor reported.
    private var baseProblems: Set<String> = []
    /// The tables a changed statement may read: the ones it read before
    /// and the ones the change may add. nil when nothing is being changed,
    /// or the statement reads no table Pharos knows.
    private var expected: Set<DraftCatalog.TableKey>?
    /// The most characters of a statement in this draft.
    private var statementLimit = SQLDraftPipeline.statementLimit
    /// Tokens kept free for the answer in this draft.
    private var answerReserve = SQLDraftPipeline.answerReserve

    let catalog: DraftCatalog
    let defaultSchema: String?
    /// Called on the main actor as each step starts.
    var onStage: ((Stage) -> Void)?

    /// One backend for the whole draft, so every step asks the same model.
    private let backend = IntelligenceBackends.current

    /// Greedy: the same request against the same schema gives the same
    /// draft, so a bad one can be reproduced.
    private let sampling = IntelligenceSampling.greedy

    private var trace: [String] = []
    /// Model requests sent in this draft.
    private var requests = 0
    /// Reading requests this draft may still send.
    private var readsLeft = SQLDraftPipeline.maxReadRequests
    /// The definitions read in this draft, a partition's among them: a
    /// table read for step 3 is not asked for again in step 4.
    private var known: [DraftCatalog.TableKey: DraftCatalog.Definition] = [:]

    /// The engine's dialect name for the instructions (`inDialect`).
    private let dialect: String

    /// Where the tables' DDL comes from; nil drafts from names, types and
    /// keys alone, with no step 3.
    private let definitions: DefinitionSource?

    init(catalog: DraftCatalog, defaultSchema: String?, dialect: String = "PostgreSQL",
         definitions: DefinitionSource? = nil) {
        self.catalog = catalog
        self.defaultSchema = defaultSchema
        self.dialect = dialect
        self.definitions = definitions
    }

    /// The request is never logged: it is the analyst's own words. Nor is
    /// `statement`, the SQL of the card the request is a change to: with
    /// one, the answer is that statement changed as the request asks; nil
    /// or blank drafts from the request alone.
    func draft(_ request: String, adjusting statement: String? = nil) async throws -> Result {
        trace = []
        requests = 0
        readsLeft = Self.maxReadRequests
        known = [:]
        base = nil
        baseProblems = []
        expected = nil
        statementLimit = Self.statementLimit
        answerReserve = Self.answerReserve
        var window = backend.contextSize
        if let statement = statement.map(SQLDraftPolicy.clean), !statement.isEmpty {
            guard statement.unicodeScalars.count <= Self.adjustLimit(contextSize: backend.contextSize) else {
                throw Failure.statementTooLong
            }
            base = statement
            baseProblems = Set(SQLDraftChecker.check(statement, in: catalog, defaultSchema: defaultSchema).map(\.description))
            statementLimit = max(Self.statementLimit, statement.unicodeScalars.count + Self.adjustGrowth)
            // The statement is in the request and in the answer: the tables
            // share what is left of the window.
            let cost = SQLDraftPrompt.estimateTokens(statement)
            answerReserve += cost
            window = max(1_024, window - 2 * cost)
            trace.append("adjusting a statement of ~\(cost) tokens; \(baseProblems.count) problem(s) of its own")
        }
        let budget = SQLDraftPrompt.Budget(contextSize: window)

        // Step 1: the tables the words of the request point at.
        onStage?(.finding)
        let ranked = SQLDraftRanker.shortlist(request, in: catalog, defaultSchema: defaultSchema)
            .filter { !catalog.partitions.contains($0.key) }
        let focus = SQLDraftRanker.focus(ranked)
        trace.append("shortlist: \(ranked.count), focus: " + focus.map(\.description).joined(separator: ", "))

        // A statement being changed brings its own tables. They are shown
        // whatever the request says, and the request is searched only for
        // tables it adds: "only the last 30 days" names none, and must not
        // send the model through a list of every table to find that out.
        let held = base.map { SQLDraftChecker.tablesRead($0, in: catalog, defaultSchema: defaultSchema) } ?? []
        if let base, !held.isEmpty {
            let keep = try await resolved(held)
            let added = SQLDraftRanker.additions(for: request, to: keep, in: catalog)
            trace.append("statement reads: " + keep.map(\.description).joined(separator: ", ")
                + "; the change may add: " + (added.isEmpty ? "none" : added.map(\.description).joined(separator: ", ")))
            expected = Set(held + keep + added)
            let reading = try await read(keep + added, keeping: Set(keep), request: request, budget: budget)
            var needed = reading.columns
            for key in keep { needed[key] = SQLDraftPrompt.columns(named: base, of: key, in: catalog) }
            return try await write(request, tables: reading.tables, needed: needed, budget: budget)
        }

        var candidates = SQLDraftRanker.withReferences(focus, in: catalog)
            .filter { !catalog.partitions.contains($0) }
        if candidates.isEmpty {
            // Nothing matches. A small schema is read whole; a larger one
            // is put to the model by name.
            let home = names(ranked, wholeSchema: true, excluding: [])
            guard !home.isEmpty else { throw Failure.noMatchingTables }
            if home.count <= Self.readLimit {
                candidates = home
                trace.append("no match; using the \(home.count) tables of the default schema")
            }
        }

        // Step 2: too many to read, or none: the model chooses by name.
        var chose = false
        if candidates.isEmpty || candidates.count > Self.readLimit || !fitsWithoutReading(candidates, request: request, budget: budget) {
            let list = names(ranked, wholeSchema: ranked.isEmpty, excluding: [])
            candidates = try await choose(
                request, from: list, budget: budget,
                fallback: Array((candidates.isEmpty ? list : candidates).prefix(4)))
            chose = true
        }

        // Step 3: read the candidates' DDL; keep the tables the query needs.
        var reading = try await read(candidates, request: request, budget: budget)
        if reading.tables.isEmpty, !chose {
            // The words matched tables that do not hold what was asked for.
            // The model chooses again from every other name, once.
            let others = names(ranked, wholeSchema: true, excluding: Set(candidates))
            if !others.isEmpty {
                trace.append("no candidate holds it; choosing again from \(others.count) names")
                let second = try await choose(request, from: others, budget: budget, fallback: [])
                if !second.isEmpty {
                    reading = try await read(second, request: request, budget: budget)
                    // Neither held it. The tables the words matched stay the
                    // best guess, ahead of the ones the model chose by name.
                    if reading.tables.isEmpty { candidates += second }
                }
            }
        }
        if reading.tables.isEmpty {
            // Nothing the model would keep. The draft step gets the best
            // candidates and writes the closest query it can.
            reading = Reading(tables: Array(candidates.prefix(4)), columns: [:])
            trace.append("read kept nothing; using the top \(reading.tables.count)")
        }

        return try await write(request, tables: reading.tables, needed: reading.columns, budget: budget)
    }

    /// Steps 4 to 6: write the statement from `tables`, check it, and
    /// repair it once.
    private func write(
        _ request: String, tables: [DraftCatalog.TableKey], needed: [DraftCatalog.TableKey: [String]],
        budget: SQLDraftPrompt.Budget
    ) async throws -> Result {
        // Step 4: the tables that passed, and what joins them.
        let keys = SQLDraftPrompt.withBridges(tables, in: catalog)
        let (block, instructions) = try await draftBlock(keys, needed: needed, request: request, budget: budget)
        trace.append("draft tables: " + block.tables.map(\.description).joined(separator: ", "))

        onStage?(.writing)
        let answer = try await write(writePrompt(request: request, block: block.text), instructions: instructions, step: "draft")
        var sql = SQLDraftPolicy.clean(answer.sql)
        // No second try: sampling is greedy, so the same prompt would give
        // the same empty answer.
        guard !sql.isEmpty else { throw Failure.emptyDraft }
        if let base, SQLDraftPrompt.sameStatement(sql, base) { throw Failure.unchanged }

        onStage?(.checking)
        var settled = settle(answer.sql, step: "check")
        sql = settled.sql
        if !settled.problems.isEmpty {
            onStage?(.repairing)
            // A changed statement is repaired as it was written: as a
            // change, to the draft, that corrects its errors.
            let prompt = base == nil
                ? SQLDraftPrompt.repairPrompt(request: request, block: block.text, sql: sql, problems: settled.problems)
                : SQLDraftPrompt.adjustRepairPrompt(block: block.text, sql: sql, problems: settled.problems)
            if let repaired = try? await write(prompt, instructions: instructions, step: "repair") {
                // The repair is a draft like the first: checked, and
                // corrected where the catalogue can answer for it.
                let again = settle(repaired.sql, step: "repair")
                // Keep the repair unless it made things worse.
                if !again.sql.isEmpty, again.problems.count <= settled.problems.count {
                    settled = again
                    sql = again.sql
                }
            }
        }
        let problems = settled.problems
        let fixes = settled.fixes
        let reads = SQLDraftChecker.tablesRead(sql, in: catalog, defaultSchema: defaultSchema)
        trace.append("model requests: \(requests)")
        return Result(sql: sql, reads: reads, problems: problems, fixes: fixes, tables: block.tables,
                      requests: requests, trace: trace)
    }

    // MARK: - Step 5: check

    /// A statement as the model wrote it, cleaned, checked, and corrected
    /// where the catalogue can answer for the mistake.
    private struct Settled {
        var sql: String
        /// What the check still finds; empty when clean.
        var problems: [String]
        /// What `SQLDraftFixer` changed.
        var fixes: [String]
    }

    /// Step 5, for the draft and for its repair alike: the names are
    /// checked, `SQLDraftFixer` corrects what it can, and its corrections
    /// are kept unless they made things worse. A statement that reached
    /// `statementLimit` is reported as cut off, ahead of any name: that is
    /// the worse problem, and one the fixer cannot help.
    private func settle(_ raw: String, step: String) -> Settled {
        var sql = SQLDraftPolicy.clean(raw)
        let cutOff = isCutOff(raw) ? [Self.cutOffProblem(limit: statementLimit)] : []
        // What the check said about the statement being changed is the
        // analyst's own, and stays out of it.
        func check(_ sql: String) -> [String] {
            unasked(in: sql) + SQLDraftChecker.check(sql, in: catalog, defaultSchema: defaultSchema).map(\.description)
                .filter { !baseProblems.contains($0) }
        }
        var problems = cutOff + check(sql)
        trace.append("\(step): \(problems.count) problem(s)")
        var fixes: [String] = []
        if !problems.isEmpty {
            let fixed = SQLDraftFixer.fix(sql, in: catalog, defaultSchema: defaultSchema)
            let after = cutOff + check(fixed.sql)
            trace.append("fixer: \(fixed.fixes.count) fix(es), \(after.count) problem(s)")
            if !fixed.fixes.isEmpty, after.count <= problems.count {
                sql = fixed.sql
                fixes = fixed.fixes
                problems = after
            }
        }
        return Settled(sql: sql, problems: problems, fixes: fixes)
    }

    /// What the check says about a table a changed statement reads that
    /// the statement did not read before and the request did not name.
    /// The model adds joins along the keys of the tables it is shown; a
    /// join nobody asked for changes which rows come back, and is the one
    /// kind of unfaithful change Pharos can see for certain. Read by the
    /// analyst under the draft and by the model in the repair request.
    private func unasked(in sql: String) -> [String] {
        guard let expected else { return [] }
        return SQLDraftChecker.tablesRead(sql, in: catalog, defaultSchema: defaultSchema)
            .filter { !expected.contains($0) }
            .map { "The query now reads \($0.description), which the request did not ask for. Take that table out." }
    }

    // MARK: - Step 1 and 2: names

    /// The table names the model may choose from, best first: the ranked
    /// ones, then (`wholeSchema`) the rest of the tab's schema in catalogue
    /// order. A partition is never listed; its parent stands for it.
    private func names(
        _ ranked: [SQLDraftRanker.Ranked], wholeSchema: Bool, excluding: Set<DraftCatalog.TableKey>
    ) -> [DraftCatalog.TableKey] {
        var out: [DraftCatalog.TableKey] = []
        var seen = excluding.union(catalog.partitions)
        for key in ranked.map(\.key) where seen.insert(key).inserted { out.append(key) }
        if wholeSchema, let defaultSchema {
            for table in catalog.tables where table.key.schema == defaultSchema && seen.insert(table.key).inserted {
                out.append(table.key)
            }
        }
        return out
    }

    /// With no DDL to read there is no step 3 to make the candidates
    /// smaller, so, as before DDL was read, they must fit the draft request
    /// as they are or the model chooses fewer.
    private func fitsWithoutReading(
        _ candidates: [DraftCatalog.TableKey], request: String, budget: SQLDraftPrompt.Budget
    ) -> Bool {
        guard definitions == nil else { return true }
        let direct = SQLDraftPrompt.block(candidates, in: catalog, request: request, budget: .max)
        return SQLDraftPrompt.estimateTokens(direct.text) <= budget.draftBlock
    }

    /// Step 2. The model chooses from as many of `names` as fit the list's
    /// budget, best first. A failure here is not fatal: `fallback` is a fair
    /// guess, and the later steps can still say what is missing. Only a
    /// cancellation stops the draft.
    private func choose(
        _ request: String, from names: [DraftCatalog.TableKey], budget: SQLDraftPrompt.Budget,
        fallback: [DraftCatalog.TableKey]
    ) async throws -> [DraftCatalog.TableKey] {
        guard !names.isEmpty else { return fallback }
        onStage?(.choosing)
        let list = SQLDraftPrompt.pickList(names, in: catalog, budget: budget.pickList)
        trace.append("choose: \(list.listed.count) of \(names.count) names, ~\(SQLDraftPrompt.estimateTokens(list.text)) tokens")
        do {
            let schema = try Self.pickSchema(names: list.listed.map(\.description))
            requests += 1
            let content = try await backend.respond(
                instructions: IntelligenceInstructions.inDialect(
                    IntelligenceInstructions.sqlSafety + " " + SQLDraftPrompt.pickInstructions, dialect),
                prompt: SQLDraftPrompt.pickPrompt(request: request, list: list.text), schema: schema,
                textLimits: ["reason": Self.lineLimit], sampling: sampling)
            let picked = try content.value([String].self, forProperty: "tables")
            var keys: [DraftCatalog.TableKey] = []
            for name in picked {
                if let key = list.listed.first(where: { $0.description == name }), !keys.contains(key) {
                    keys.append(key)
                }
            }
            trace.append("pick: " + keys.map(\.description).joined(separator: ", "))
            return keys.isEmpty ? fallback : keys
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("pick", error)
            trace.append("pick failed: \(Self.name(of: error)); using the top \(fallback.count)")
            return fallback
        }
    }

    // MARK: - The answers' shapes

    /// Step 2's answer: a reason, then one to `pickLimit` of `names`. The
    /// names are an enumeration, so the on-device model cannot write any
    /// other; an endpoint is sent the same thing as JSON Schema and what it
    /// answers is checked against `names` again when it is read.
    static func pickSchema(names: [String]) throws -> GenerationSchema {
        let table = DynamicGenerationSchema(name: "TableName", anyOf: names)
        let root = DynamicGenerationSchema(name: "TablePick", properties: [
            .init(name: "reason", description: "which tables hold the data, and how they join",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "tables", schema: DynamicGenerationSchema(
                arrayOf: table, minimumElements: 1, maximumElements: SQLDraftPrompt.pickLimit)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Step 3's answer: a plan, then for each table the query needs, its
    /// name (one of `names`) and the columns it needs. None is an answer.
    static func readSchema(names: [String]) throws -> GenerationSchema {
        let use = DynamicGenerationSchema(name: "TableUse", properties: [
            .init(name: "table", schema: DynamicGenerationSchema(name: "TableName", anyOf: names)),
            .init(name: "columns", description: "the columns of this table the query needs",
                  schema: DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 12)),
        ])
        let root = DynamicGenerationSchema(name: "TableReading", properties: [
            .init(name: "plan", description: "what the query needs and which tables hold it, in one short line",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "tables", schema: DynamicGenerationSchema(
                arrayOf: use, minimumElements: 0, maximumElements: names.count)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    // MARK: - Step 3: read

    /// What step 3 found: the tables the query needs, in candidate order,
    /// and the columns of each that the model named.
    private struct Reading {
        var tables: [DraftCatalog.TableKey]
        var columns: [DraftCatalog.TableKey: [String]]
    }

    /// `keys` with each partition replaced by the table it is a partition
    /// of, in order and once each, and their definitions read into `known`.
    /// A table whose definition could not be read stays in the list: it can
    /// still be shown by its names, types and keys.
    private func resolved(_ keys: [DraftCatalog.TableKey]) async throws -> [DraftCatalog.TableKey] {
        func once(_ keys: [DraftCatalog.TableKey]) -> [DraftCatalog.TableKey] {
            var seen = Set<DraftCatalog.TableKey>()
            return keys.filter { catalog.table($0) != nil && seen.insert($0).inserted }
        }
        var wanted = once(keys)
        guard let definitions else { return wanted }
        // A partition of a partition takes one round each; three is deeper
        // than partitioning goes in practice.
        for _ in 0..<3 {
            let missing = wanted.filter { known[$0] == nil }
            if !missing.isEmpty {
                known.merge(await definitions(missing)) { _, new in new }
                try Task.checkCancellation()
            }
            let parents = once(wanted.map { known[$0]?.partitionOf ?? $0 })
            if parents == wanted { break }
            wanted = parents
        }
        return wanted
    }

    /// The DDL read so far that may be shown: a partition's is not, because
    /// it carries the partition's bounds.
    private var shownDefinitions: [DraftCatalog.TableKey: String] {
        known.compactMapValues { $0.partitionOf == nil ? $0.ddl : nil }
    }

    /// Step 3. Reads the candidates' DDL and asks the model which of them
    /// the query needs, in as few requests as keep each inside
    /// `budget.readBlock` and no more than the draft has left
    /// (`maxReadRequests`). A table that could not be read, is too large to
    /// show whole, or is over that limit is kept without being asked about. A request that
    /// fails keeps its tables too: step 3 only ever removes a table the
    /// model looked at and did not want.
    ///
    /// `keeping` are tables the query reads already (a statement being
    /// changed): they are kept and the model is not asked about them. It
    /// is asked about the others when all of them together are too much
    /// to write from unread.
    private func read(
        _ candidates: [DraftCatalog.TableKey], keeping: Set<DraftCatalog.TableKey> = [],
        request: String, budget: SQLDraftPrompt.Budget
    ) async throws -> Reading {
        guard definitions != nil, !candidates.isEmpty else { return Reading(tables: candidates, columns: [:]) }
        onStage?(.reading)
        let tables = try await resolved(candidates)
        let ddl = shownDefinitions
        let (packs, unread) = SQLDraftPrompt.readPacks(
            tables.filter { !keeping.contains($0) }, definitions: ddl, in: catalog,
            budget: budget.readBlock, limit: readsLeft)
        let readable = packs.flatMap { $0 }
        trace.append("read: \(readable.count) of \(tables.count) tables in \(packs.count) request(s)")

        let ask: Bool
        switch Self.readPolicy {
        case .always:
            ask = !readable.isEmpty
        case .whenLarge:
            let all = SQLDraftPrompt.ddlBlock(tables, definitions: ddl, in: catalog)
            ask = !readable.isEmpty
                && (all.tables.count < tables.count || SQLDraftPrompt.estimateTokens(all.text) > budget.draftUnread)
        }
        guard ask else {
            trace.append("read: small enough to write from as it is")
            return Reading(tables: tables, columns: [:])
        }

        var kept = Set(unread).union(keeping)
        var columns: [DraftCatalog.TableKey: [String]] = [:]
        for pack in packs {
            readsLeft -= 1
            let block = SQLDraftPrompt.ddlBlock(pack, definitions: ddl, in: catalog)
            do {
                let uses = try await which(of: pack, block: block.text, request: readRequest(request))
                for (key, named) in uses {
                    kept.insert(key)
                    columns[key] = named
                }
                trace.append("read ~\(SQLDraftPrompt.estimateTokens(block.text)) tokens: kept "
                    + (uses.isEmpty ? "none" : uses.map {
                        "\($0.key.description)(\($0.columns.joined(separator: " ")))"
                    }.joined(separator: ", ")))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("read", error)
                trace.append("read failed: \(Self.name(of: error)); keeping its \(pack.count) table(s)")
                kept.formUnion(pack)
            }
        }
        return Reading(tables: tables.filter(kept.contains), columns: columns)
    }

    /// One "which of these tables" request. The answer is held to the names
    /// in `pack`; a column the table does not have is dropped.
    private func which(
        of pack: [DraftCatalog.TableKey], block: String, request: String
    ) async throws -> [(key: DraftCatalog.TableKey, columns: [String])] {
        let schema = try Self.readSchema(names: pack.map(\.description))
        requests += 1
        let content = try await backend.respond(
            instructions: IntelligenceInstructions.inDialect(
                IntelligenceInstructions.sqlSafety + " " + SQLDraftPrompt.readInstructions, dialect),
            prompt: SQLDraftPrompt.readPrompt(request: request, block: block), schema: schema,
            textLimits: ["plan": Self.lineLimit, "columns": Self.nameLimit], sampling: sampling)
        var out: [(key: DraftCatalog.TableKey, columns: [String])] = []
        for use in try content.value([GeneratedContent].self, forProperty: "tables") {
            let name = try use.value(String.self, forProperty: "table")
            guard let key = pack.first(where: { $0.description == name }), let table = catalog.table(key),
                  !out.contains(where: { $0.key == key }) else { continue }
            let named = (try? use.value([String].self, forProperty: "columns")) ?? []
            out.append((key, SQLDraftPrompt.columns(named, of: table)))
        }
        return out
    }

    // MARK: - Step 4: the tables the draft is shown

    /// `keys` as the draft step sees them: their DDL when every table has
    /// one and it fits, and otherwise the compact block, which keeps the
    /// keys and the columns step 3 named and trims the rest to fit.
    private func draftBlock(
        _ keys: [DraftCatalog.TableKey], needed: [DraftCatalog.TableKey: [String]],
        request: String, budget: SQLDraftPrompt.Budget
    ) async throws -> (block: (text: String, tables: [DraftCatalog.TableKey]), instructions: String) {
        var keys = keys
        if definitions != nil {
            // A table that joins two others arrives here unread.
            keys = try await resolved(keys)
            let ddl = SQLDraftPrompt.ddlBlock(keys, definitions: shownDefinitions, in: catalog)
            if ddl.tables.count == keys.count, await fits(ddl.text, request: request, budget: budget) {
                trace.append("draft: DDL of \(ddl.tables.count) table(s), ~\(SQLDraftPrompt.estimateTokens(ddl.text)) tokens")
                return (ddl, ddlInstructions)
            }
            trace.append("draft: DDL does not fit or is not all read; compact block")
        }
        var block = SQLDraftPrompt.block(keys, in: catalog, request: request, budget: budget.draftBlock, needed: needed)
        block = await fitted(block, keys: keys, request: request, budget: budget.draftBlock, needed: needed)
        return (block, draftInstructions)
    }

    /// Whether a DDL block may go in the draft request: under the ceiling,
    /// and leaving room for the answer — by the model's own count where it
    /// can count, by the estimate where it cannot.
    private func fits(_ block: String, request: String, budget: SQLDraftPrompt.Budget) async -> Bool {
        guard SQLDraftPrompt.estimateTokens(block) <= SQLDraftPrompt.Budget.draftCeiling else { return false }
        do {
            let used = try await backend.tokenCount(
                instructions: ddlInstructions,
                prompt: writePrompt(request: request, block: block),
                schema: SQLDraft.generationSchema)
            trace.append("prompt tokens: \(used) of \(backend.contextSize)")
            return used + answerReserve <= backend.contextSize
        } catch {
            return SQLDraftPrompt.estimateTokens(block) <= budget.draftDefinitions
        }
    }

    /// The estimate is conservative, but where the model can count (macOS
    /// 26.4 and later for the on-device one) the real count is one call
    /// away: when the full prompt would not leave room for
    /// the answer, the block is rebuilt smaller, once.
    private func fitted(
        _ block: (text: String, tables: [DraftCatalog.TableKey]),
        keys: [DraftCatalog.TableKey], request: String, budget: Int,
        needed: [DraftCatalog.TableKey: [String]]
    ) async -> (text: String, tables: [DraftCatalog.TableKey]) {
        do {
            let used = try await backend.tokenCount(
                instructions: draftInstructions,
                prompt: writePrompt(request: request, block: block.text),
                schema: SQLDraft.generationSchema)
            trace.append("prompt tokens: \(used) of \(backend.contextSize)")
            let over = used + answerReserve - backend.contextSize
            guard over > 0 else { return block }
            let smaller = SQLDraftPrompt.block(
                keys, in: catalog, request: request,
                budget: budget - over - over / 5,
                needed: needed,
                estimate: SQLDraftPrompt.estimateTokens)
            trace.append("rebuilt smaller: over by \(over)")
            return smaller
        } catch {
            return block
        }
    }

    private var draftInstructions: String {
        IntelligenceInstructions.inDialect(IntelligenceInstructions.sqlSafety + " "
            + (base == nil ? SQLDraftPrompt.draftInstructions : SQLDraftPrompt.adjustInstructions), dialect)
    }

    /// The instructions that go with a block of DDL.
    private var ddlInstructions: String {
        IntelligenceInstructions.inDialect(IntelligenceInstructions.sqlSafety + " "
            + (base == nil ? SQLDraftPrompt.ddlDraftInstructions : SQLDraftPrompt.ddlAdjustInstructions), dialect)
    }

    /// The writing request: the tables and the request, and between them
    /// the statement the request is a change to, when there is one.
    private func writePrompt(request: String, block: String) -> String {
        base.map { SQLDraftPrompt.adjustPrompt(request: request, block: block, sql: $0) }
            ?? SQLDraftPrompt.draftPrompt(request: request, block: block)
    }

    /// The request as the reading step is asked it. A change is said to be
    /// one: "add the customer's name" is not a query on its own.
    private func readRequest(_ request: String) -> String {
        base == nil ? request : "a change to an existing query: " + request
    }

    /// Steps 4 and 6: one new request per answer, under the instructions
    /// that match the block in the prompt.
    private func write(_ prompt: String, instructions: String, step: String) async throws -> SQLDraft {
        do {
            requests += 1
            let draft: SQLDraft
            if base == nil {
                draft = try await backend.respond(
                    instructions: instructions, prompt: prompt, generating: SQLDraft.self, sampling: sampling)
            } else {
                // A changed statement may be as long as the one it changes:
                // the same answer, asked for with this draft's own limit.
                var limits = SQLDraft.textLimits
                limits["sql"] = statementLimit
                draft = try SQLDraft(await backend.respond(
                    instructions: instructions, prompt: prompt, schema: SQLDraft.generationSchema,
                    textLimits: limits, sampling: sampling))
            }
            Log.intelligence.info("draft-sql: \(step, privacy: .public) answered")
            return draft
        } catch {
            log(step, error)
            trace.append("\(step) failed: \(Self.name(of: error))")
            throw error
        }
    }

    // MARK: - Errors

    private func log(_ step: String, _ error: Error) {
        Log.intelligence.error(
            "draft-sql: \(step, privacy: .public) failed: \(Self.name(of: error), privacy: .public)")
    }

    /// The error's case, never its payload, on macOS 26 and 27 alike.
    static func name(of error: Error) -> String {
        ModelErrorKind.of(error).name
    }
}
