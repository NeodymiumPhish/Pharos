import Foundation
import FoundationModels

/// "Describe the query": a sentence in, one `SELECT` out.
///
/// Drafting runs in steps, each model step in a NEW session with greedy
/// sampling and no tools. The on-device model has a 4096-token window, so
/// Pharos does the searching and the model does the writing:
///
/// 1. Rank (code): `SQLDraftRanker` matches the request to table, column and
///    comment names, and adds foreign-key neighbours. Its strongest hits,
///    plus the tables they reference, are the focus.
/// 2. Pick (model, only when needed): when the focus is too large for one
///    prompt, the model chooses from the whole shortlist by name. Its answer
///    is constrained to those names, so it cannot invent one.
/// 3. Assemble (code): the chosen tables, plus any table that joins two of
///    them, as a compact block with types, keys and enum values.
/// 4. Draft (model): the block and the request in, `SQLDraft` out.
/// 5. Check (code): `SQLDraftChecker` finds names that do not exist, and
///    `SQLDraftFixer` corrects what the catalogue can answer for: a join on
///    the wrong columns, a column read through the wrong alias, a missing
///    pair of quotes.
/// 6. Repair (model, at most once, only for what is left): the draft and its
///    problems in, a corrected draft out.
///
/// Every string the model receives is built from a `DraftCatalog`, which has
/// no field that could hold a row value. Nothing here runs SQL: `draft`
/// returns text, `SQLDraftPolicy` reviews it, and the analyst decides.
/// Replaces a single session that looked names up with two tools. Measured
/// with `scripts/eval-sql-draft.sh` (22 requests, a 26-table fixture, the
/// macOS 27 model, 2026-10-05): the tool design answered none — 21 ran out
/// of the 4096-token window after 65–117 s and one never finished — and
/// this pipeline answers 17 with SQL that runs and names the right tables,
/// median 7.4 s. Reading the 17, about 10 answer the request exactly; the
/// rest join tables the request did not need or pick the wrong aggregate.

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
    /// statement that answered it, so the popover says what the statement
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

// MARK: - Pipeline

@MainActor
final class SQLDraftPipeline {

    enum Stage: Equatable {
        case finding, choosing, writing, checking, repairing
    }

    enum Failure: LocalizedError, Equatable {
        /// No table or column name resembles the request.
        case noMatchingTables
        /// The model answered with no statement.
        case emptyDraft

        var errorDescription: String? {
            switch self {
            case .noMatchingTables:
                return String(localized: "No table matches that description. Name a table or column, or choose the schema that holds the data.")
            case .emptyDraft:
                return String(localized: "The model could not draft a query. Try describing it another way.")
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
        /// Step by step, for the evaluation harness. Holds table names and
        /// counts, never the request or the SQL, and is never logged.
        let trace: [String]
    }

    /// At most this many candidates go straight to the draft step without a
    /// pick, when they also fit the budget.
    static let directLimit = 8

    /// Tokens kept free for the answer: plan, statement and note.
    static let answerReserve = 700

    let catalog: DraftCatalog
    let defaultSchema: String?
    /// Called on the main actor as each step starts.
    var onStage: ((Stage) -> Void)?

    private let model = SystemLanguageModel.default

    /// Greedy: the same request against the same schema gives the same
    /// draft, so a bad one can be reproduced. The macOS 27 SDK renames
    /// `sampling:` to `samplingMode:` (back-deployed, so it runs on macOS 26
    /// too) and deprecates the old name; the macOS 26 SDK of release CI
    /// (Xcode 26.6, Swift 6.3) has only the old name. Swift 6.4 comes with
    /// the macOS 27 SDK, so the compiler version picks the spelling. Drop the
    /// `#else` once release CI builds with Xcode 27.
    #if compiler(>=6.4)
    private let options = GenerationOptions(samplingMode: .greedy)
    #else
    private let options = GenerationOptions(sampling: .greedy)
    #endif

    private var trace: [String] = []

    init(catalog: DraftCatalog, defaultSchema: String?) {
        self.catalog = catalog
        self.defaultSchema = defaultSchema
    }

    /// The request is never logged: it is the analyst's own words.
    func draft(_ request: String) async throws -> Result {
        trace = []
        onStage?(.finding)
        let candidates = try candidates(for: request)

        let budget = SQLDraftPrompt.blockBudget(contextSize: model.contextSize)
        var chosen = SQLDraftRanker.withReferences(candidates.focus, in: catalog)
        let direct = SQLDraftPrompt.block(chosen, in: catalog, request: request, budget: .max)
        if chosen.count > Self.directLimit || SQLDraftPrompt.estimateTokens(direct.text) > budget {
            onStage?(.choosing)
            chosen = try await pick(request, from: candidates.all)
        }
        let keys = SQLDraftPrompt.withBridges(chosen, in: catalog)
        var block = SQLDraftPrompt.block(keys, in: catalog, request: request, budget: budget)
        block = await fitted(block, keys: keys, request: request, budget: budget)
        trace.append("draft tables: " + block.tables.map(\.description).joined(separator: ", "))

        onStage?(.writing)
        let answer = try await write(SQLDraftPrompt.draftPrompt(request: request, block: block.text), step: "draft")
        var sql = SQLDraftPolicy.clean(answer.sql)
        // No second try: sampling is greedy, so the same prompt would give
        // the same empty answer.
        guard !sql.isEmpty else { throw Failure.emptyDraft }

        onStage?(.checking)
        var problems = SQLDraftChecker.check(sql, in: catalog, defaultSchema: defaultSchema).map(\.description)
        trace.append("check: \(problems.count) problem(s)")
        var fixes: [String] = []
        if !problems.isEmpty {
            let fixed = SQLDraftFixer.fix(sql, in: catalog, defaultSchema: defaultSchema)
            let after = SQLDraftChecker.check(fixed.sql, in: catalog, defaultSchema: defaultSchema).map(\.description)
            trace.append("fixer: \(fixed.fixes.count) fix(es), \(after.count) problem(s)")
            // Keep the fixes unless they made things worse.
            if !fixed.fixes.isEmpty, after.count <= problems.count {
                sql = fixed.sql
                fixes = fixed.fixes
                problems = after
            }
        }
        if !problems.isEmpty {
            onStage?(.repairing)
            let prompt = SQLDraftPrompt.repairPrompt(request: request, block: block.text, sql: sql, problems: problems)
            if let repaired = try? await write(prompt, step: "repair") {
                let repairedSQL = SQLDraftPolicy.clean(repaired.sql)
                let after = SQLDraftChecker.check(repairedSQL, in: catalog, defaultSchema: defaultSchema).map(\.description)
                trace.append("repair: \(after.count) problem(s)")
                // Keep the repair unless it made things worse.
                if !repairedSQL.isEmpty, after.count <= problems.count {
                    sql = repairedSQL
                    problems = after
                }
            }
        }
        let reads = SQLDraftChecker.tablesRead(sql, in: catalog, defaultSchema: defaultSchema)
        return Result(sql: sql, reads: reads, problems: problems, fixes: fixes, tables: block.tables, trace: trace)
    }

    // MARK: - Steps

    /// Step 1. When nothing matches, a small default schema is offered whole:
    /// a vague request against a ten-table schema is still answerable.
    private func candidates(for request: String) throws -> (all: [DraftCatalog.TableKey], focus: [DraftCatalog.TableKey]) {
        let ranked = SQLDraftRanker.shortlist(request, in: catalog, defaultSchema: defaultSchema)
        let focus = SQLDraftRanker.focus(ranked)
        trace.append("shortlist: \(ranked.count), focus: " + focus.map(\.description).joined(separator: ", "))
        if !ranked.isEmpty { return (ranked.map(\.key), focus) }
        let home = catalog.tables.filter { $0.key.schema == defaultSchema }.map(\.key)
        guard !home.isEmpty, home.count <= Self.directLimit else { throw Failure.noMatchingTables }
        trace.append("no match; using the \(home.count) tables of the default schema")
        return (home, home)
    }

    /// Step 2. A failure here is not fatal: the ranker's best few are a
    /// fair guess, and the draft step can still say what is missing. Only a
    /// cancellation stops the draft.
    private func pick(_ request: String, from candidates: [DraftCatalog.TableKey]) async throws -> [DraftCatalog.TableKey] {
        let fallback = Array(candidates.prefix(4))
        let names = candidates.map(\.description)
        do {
            let table = DynamicGenerationSchema(name: "TableName", anyOf: names)
            let root = DynamicGenerationSchema(name: "TablePick", properties: [
                .init(name: "reason", description: "which tables hold the data, and how they join",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "tables", schema: DynamicGenerationSchema(
                    arrayOf: table, minimumElements: 1, maximumElements: SQLDraftPrompt.pickLimit)),
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(
                instructions: IntelligenceInstructions.sqlSafety + " " + SQLDraftPrompt.pickInstructions)
            let list = SQLDraftPrompt.pickList(candidates, in: catalog)
            let response = try await session.respond(
                to: SQLDraftPrompt.pickPrompt(request: request, list: list), schema: schema, options: options)
            let picked = try response.content.value([String].self, forProperty: "tables")
            var keys: [DraftCatalog.TableKey] = []
            for name in picked {
                if let key = candidates.first(where: { $0.description == name }), !keys.contains(key) {
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

    /// The estimate is conservative, but on macOS 26.4 and later the real
    /// count is one call away: when the full prompt would not leave room for
    /// the answer, the block is rebuilt smaller, once.
    private func fitted(
        _ block: (text: String, tables: [DraftCatalog.TableKey]),
        keys: [DraftCatalog.TableKey], request: String, budget: Int
    ) async -> (text: String, tables: [DraftCatalog.TableKey]) {
        guard #available(macOS 26.4, *) else { return block }
        do {
            let used = try await promptTokens(for: block.text, request: request)
            trace.append("prompt tokens: \(used) of \(model.contextSize)")
            let over = used + Self.answerReserve - model.contextSize
            guard over > 0 else { return block }
            let smaller = SQLDraftPrompt.block(
                keys, in: catalog, request: request,
                budget: budget - over - over / 5,
                estimate: SQLDraftPrompt.estimateTokens)
            trace.append("rebuilt smaller: over by \(over)")
            return smaller
        } catch {
            return block
        }
    }

    @available(macOS 26.4, *)
    private func promptTokens(for block: String, request: String) async throws -> Int {
        let instructions = Instructions(Self.draftInstructions)
        let prompt = SQLDraftPrompt.draftPrompt(request: request, block: block)
        let a = try await model.tokenCount(for: instructions)
        let b = try await model.tokenCount(for: prompt)
        let c = try await model.tokenCount(for: SQLDraft.generationSchema)
        return a + b + c
    }

    private static var draftInstructions: String {
        IntelligenceInstructions.sqlSafety + " " + SQLDraftPrompt.draftInstructions
    }

    /// Steps 4 and 6: one new session per answer.
    private func write(_ prompt: String, step: String) async throws -> SQLDraft {
        let session = LanguageModelSession(instructions: Self.draftInstructions)
        do {
            let response = try await session.respond(to: prompt, generating: SQLDraft.self, options: options)
            Log.intelligence.info("draft-sql: \(step, privacy: .public) answered")
            return response.content
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
