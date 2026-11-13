import Foundation
import FoundationModels

// Tests for the model half of the "Describe a query" pipeline:
// `SQLDraftPipeline`, asked through a stand-in `IntelligenceBackend`. Run by
// scripts/test-sql-draft-backend.sh.
//
// The stand-in answers from a queue and records every request, so these
// check what the pipeline sends (which instructions, which sampling, how
// many requests) and what it does with an answer. Whether a real model
// answers well is scripts/eval-sql-draft.sh's question, not this file's.

private var failures = 0
private var passes = 0

private func expect(_ condition: Bool, _ message: String, line: Int = #line) {
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

// MARK: - The stand-in

@MainActor
private final class FakeBackend: IntelligenceBackend {

    struct Request {
        enum Kind { case typed, schema }
        let kind: Kind
        let instructions: String
        let prompt: String
        let sampling: IntelligenceSampling
    }

    struct Refused: Error {}

    var contextSize = 4096
    /// JSON answers for typed requests, first in, first out. Nil throws.
    var typedAnswers: [String?] = []
    /// JSON answers for run-time schemas. Nil throws.
    var schemaAnswers: [String?] = []
    /// Nil means the model cannot count.
    var tokens: Int?
    private(set) var requests: [Request] = []

    func respond<Answer: Generable>(
        instructions: String, prompt: String,
        generating type: Answer.Type, sampling: IntelligenceSampling
    ) async throws -> Answer {
        requests.append(Request(kind: .typed, instructions: instructions, prompt: prompt, sampling: sampling))
        guard !typedAnswers.isEmpty, let json = typedAnswers.removeFirst() else { throw Refused() }
        return try Answer(GeneratedContent(json: json))
    }

    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        requests.append(Request(kind: .schema, instructions: instructions, prompt: prompt, sampling: sampling))
        guard !schemaAnswers.isEmpty, let json = schemaAnswers.removeFirst() else { throw Refused() }
        return try GeneratedContent(json: json)
    }

    func streamResponse<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type
    ) -> AsyncThrowingStream<Answer.PartiallyGenerated, Error> {
        AsyncThrowingStream { $0.finish(throwing: Refused()) }
    }

    func tokenCount(instructions: String, prompt: String, schema: GenerationSchema) async throws -> Int {
        guard let tokens else { throw IntelligenceBackendError.tokenCountUnavailable }
        return tokens
    }
}

private func json(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func draftJSON(_ sql: String) -> String {
    json(["plan": "p", "sql": sql, "note": "n"])
}

// MARK: - Fixtures

private typealias Key = DraftCatalog.TableKey
private typealias Source = DraftCatalog.SourceColumn

private let orders = Key(schema: "sales", name: "orders")
private let customers = Key(schema: "sales", name: "customers")

private func smallCatalog() -> DraftCatalog {
    let columns: [Key: [Source]] = [
        orders: [Source(name: "id", type: "bigint", isPrimaryKey: true),
                 Source(name: "customer_id", type: "bigint", isPrimaryKey: false),
                 Source(name: "placed_at", type: "timestamp with time zone", isPrimaryKey: false)],
        customers: [Source(name: "id", type: "bigint", isPrimaryKey: true),
                    Source(name: "name", type: "text", isPrimaryKey: false)],
    ]
    let facts = SchemaDraftFacts(foreignKeys: [
        .init(table: "orders", columns: ["customer_id"], refSchema: "sales", refTable: "customers", refColumns: ["id"]),
    ])
    return DraftCatalog(columns: columns, facts: ["sales": facts])
}

/// Three tables that all match "invoice" and are too wide to fit one prompt
/// in the smallest window, so the pipeline has to ask which to use.
private let wideKeys = ["invoice_lines", "invoice_headers", "invoice_payments"].map { Key(schema: "sales", name: $0) }

private func wideCatalog() -> DraftCatalog {
    var columns: [Key: [Source]] = [:]
    for key in wideKeys {
        columns[key] = [Source(name: "id", type: "bigint", isPrimaryKey: true)]
            + (1...60).map { Source(name: "invoice_measurement_column_\($0)", type: "numeric", isPrimaryKey: false) }
    }
    return DraftCatalog(columns: columns, facts: [:])
}

@MainActor
private func withBackend(_ backend: FakeBackend, _ body: () async throws -> Void) async rethrows {
    IntelligenceBackends.overrideForTesting = backend
    defer { IntelligenceBackends.overrideForTesting = nil }
    try await body()
}

// MARK: - Tests

@MainActor
private func testDraftGoesThroughTheBackend() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.orders;")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        do {
            let result = try await pipeline.draft("orders placed this week")
            expect(result.sql.hasPrefix("SELECT id FROM sales.orders"), "the answer's statement is the draft: \(result.sql)")
            expectEqual(result.problems, [], "a statement over real names has no problems")
            expectEqual(result.reads, [orders], "the draft reads orders")
        } catch {
            expect(false, "draft threw \(error)")
        }
        expectEqual(stages, [.finding, .writing, .checking], "a small schema needs no pick and no repair")
        expectEqual(backend.requests.count, 1, "one request for one draft")
        guard let request = backend.requests.first else { return }
        expect(request.kind == .typed, "the draft asks for a SQLDraft")
        expect(request.sampling == .greedy, "the draft is sampled greedily")
        expect(request.instructions.hasPrefix(IntelligenceInstructions.sqlSafety), "the safety sentences come first")
        expect(request.instructions.contains(SQLDraftPrompt.draftInstructions), "then the draft instructions")
        expect(request.prompt.contains("orders placed this week"), "the prompt carries the request")
        expect(request.prompt.contains("customer_id"), "the prompt carries the table block")
    }
}

@MainActor
private func testDialectReachesTheInstructions() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.orders")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales", dialect: "DuckDB")
        _ = try? await pipeline.draft("orders")
        let instructions = backend.requests.first?.instructions ?? ""
        expect(instructions.contains("DuckDB") && !instructions.contains("PostgreSQL"), "another engine swaps the name")
    }
}

@MainActor
private func testBackendIsFixedForOneDraft() async {
    let first = FakeBackend()
    first.typedAnswers = [draftJSON("SELECT id FROM sales.orders")]
    let second = FakeBackend()
    IntelligenceBackends.overrideForTesting = first
    let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
    IntelligenceBackends.overrideForTesting = second
    _ = try? await pipeline.draft("orders")
    IntelligenceBackends.overrideForTesting = nil
    expectEqual(first.requests.count, 1, "a pipeline keeps the backend it was made with")
    expectEqual(second.requests.count, 0, "a later change does not split one draft across two models")
}

/// A draft is put in the editor for the analyst to read, so it must be what
/// it looks like: no character that reorders or hides part of it.
@MainActor
private func testDraftCarriesNoInvisibleCharacters() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("SELECT id\u{202E}\n  FROM sales.\u{200B}orders\u{00A0}WHERE id > 0\u{2066}")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            let result = try await pipeline.draft("orders")
            expectEqual(result.sql, "SELECT id\n  FROM sales.orders WHERE id > 0",
                        "bidi and zero-width characters go, the line break stays, an odd space becomes a plain one")
            expectEqual(result.problems, [], "and the names check as the ones they look like")
        } catch {
            expect(false, "draft threw \(error)")
        }
    }
}

@MainActor
private func testEmptyAnswerIsAFailure() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("   ")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            _ = try await pipeline.draft("orders")
            expect(false, "an empty statement must throw")
        } catch let failure as SQLDraftPipeline.Failure {
            expectEqual(failure, .emptyDraft, "an empty statement is emptyDraft")
        } catch {
            expect(false, "unexpected error \(error)")
        }
        expectEqual(backend.requests.count, 1, "greedy sampling: no second try at the same prompt")
    }
}

@MainActor
private func testBackendErrorIsPassedOn() async {
    let backend = FakeBackend()
    backend.typedAnswers = [nil]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            _ = try await pipeline.draft("orders")
            expect(false, "a refused draft must throw")
        } catch {
            expect(error is FakeBackend.Refused, "the backend's own error reaches the caller")
        }
    }
}

@MainActor
private func testRepairAsksOnceMore() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.nothing_here"), draftJSON("SELECT id FROM sales.orders")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        do {
            let result = try await pipeline.draft("orders")
            expectEqual(result.sql, "SELECT id FROM sales.orders", "the repaired statement replaces the draft")
            expectEqual(result.problems, [], "and has no problems left")
        } catch {
            expect(false, "draft threw \(error)")
        }
        expect(stages.contains(.repairing), "a name that does not exist starts a repair")
        expectEqual(backend.requests.count, 2, "one draft and one repair")
        let repair = backend.requests.last
        expect(repair?.prompt.contains("nothing_here") == true, "the repair prompt carries the draft")
        expect(repair?.sampling == .greedy, "the repair is greedy too")
    }
}

@MainActor
private func testFailedRepairKeepsTheDraft() async {
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.nothing_here"), nil]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            let result = try await pipeline.draft("orders")
            expectEqual(result.sql, "SELECT id FROM sales.nothing_here", "the draft stays when the repair fails")
            expect(!result.problems.isEmpty, "and its problem is reported, not hidden")
        } catch {
            expect(false, "a failed repair must not fail the draft: \(error)")
        }
    }
}

@MainActor
private func testPickIsHeldToTheList() async {
    let backend = FakeBackend()
    backend.contextSize = 0
    backend.schemaAnswers = [json(["reason": "r", "tables": [wideKeys[1].description, "sales.invented", wideKeys[1].description]])]
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.invoice_headers")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: wideCatalog(), defaultSchema: "sales")
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        do {
            let result = try await pipeline.draft("invoice totals")
            expectEqual(result.tables, [wideKeys[1]], "only the listed name survives, once")
        } catch {
            expect(false, "draft threw \(error)")
        }
        expect(stages.contains(.choosing), "tables too wide for one prompt start a pick")
        expectEqual(backend.requests.map(\.kind), [.schema, .typed], "the pick, then the draft")
        let pick = backend.requests.first
        expect(pick?.sampling == .greedy, "the pick is greedy")
        expect(pick?.instructions.contains(SQLDraftPrompt.pickInstructions) == true, "the pick has its own instructions")
        for key in wideKeys {
            expect(pick?.prompt.contains(key.name) == true, "the pick list names \(key.name)")
        }
    }
}

@MainActor
private func testFailedPickFallsBack() async {
    let backend = FakeBackend()
    backend.contextSize = 0
    backend.schemaAnswers = [nil]
    backend.typedAnswers = [draftJSON("SELECT id FROM sales.invoice_lines")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: wideCatalog(), defaultSchema: "sales")
        do {
            let result = try await pipeline.draft("invoice totals")
            expect(!result.tables.isEmpty, "the ranker's best stand in for a failed pick")
            expect(result.trace.contains { $0.hasPrefix("pick failed") }, "and the trace says so")
        } catch {
            expect(false, "a failed pick must not fail the draft: \(error)")
        }
        expectEqual(backend.requests.count, 2, "the draft is still asked for")
    }
}

@MainActor
private func testTokenCountShrinksTheBlock() async {
    let uncounted = FakeBackend()
    uncounted.typedAnswers = [draftJSON("SELECT id FROM sales.orders")]
    var plainPrompt = ""
    await withBackend(uncounted) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("orders")
        plainPrompt = uncounted.requests.first?.prompt ?? ""
        expect(result?.trace.contains { $0.hasPrefix("prompt tokens") } == false, "a model that cannot count leaves the estimate alone")
    }

    let counted = FakeBackend()
    counted.tokens = 4000
    counted.typedAnswers = [draftJSON("SELECT id FROM sales.orders")]
    await withBackend(counted) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("orders")
        let trace = result?.trace ?? []
        expect(trace.contains("prompt tokens: 4000 of 4096"), "the real count is traced: \(trace)")
        expect(trace.contains { $0.hasPrefix("rebuilt smaller") }, "a prompt with no room for the answer is rebuilt")
        expect(!plainPrompt.isEmpty, "the uncounted run produced a prompt to compare with")
    }
}

// MARK: - Reading the tables' DDL

private let regions = Key(schema: "sales", name: "regions")

/// `smallCatalog` plus a table with no key to or from anything.
private func threeTables() -> DraftCatalog {
    let columns: [Key: [Source]] = [
        orders: [Source(name: "id", type: "bigint", isPrimaryKey: true),
                 Source(name: "customer_id", type: "bigint", isPrimaryKey: false),
                 Source(name: "placed_at", type: "timestamp with time zone", isPrimaryKey: false)],
        customers: [Source(name: "id", type: "bigint", isPrimaryKey: true),
                    Source(name: "name", type: "text", isPrimaryKey: false)],
        regions: [Source(name: "code", type: "text", isPrimaryKey: true),
                  Source(name: "label", type: "text", isPrimaryKey: false)],
    ]
    let facts = SchemaDraftFacts(foreignKeys: [
        .init(table: "orders", columns: ["customer_id"], refSchema: "sales", refTable: "customers", refColumns: ["id"]),
    ])
    return DraftCatalog(columns: columns, facts: ["sales": facts])
}

private func ddl(_ key: Key, _ columns: [String]) -> String {
    "CREATE TABLE \"\(key.schema)\".\"\(key.name)\" (\n" + columns.map { "    \"\($0)\" bigint" }.joined(separator: ",\n") + "\n);"
}

/// A definition source over a fixed set, which records what it was asked for.
@MainActor
private final class Definitions {
    var all: [Key: DraftCatalog.Definition]
    private(set) var asked: [[Key]] = []

    init(_ all: [Key: DraftCatalog.Definition]) { self.all = all }

    var source: SQLDraftPipeline.DefinitionSource {
        { [self] keys in
            asked.append(keys)
            return all.filter { keys.contains($0.key) }
        }
    }

    static func plain(_ catalog: DraftCatalog) -> Definitions {
        var all: [Key: DraftCatalog.Definition] = [:]
        for table in catalog.tables {
            all[table.key] = .init(ddl: ddl(table.key, table.columns.map(\.name)), partitionOf: nil)
        }
        return Definitions(all)
    }
}

/// Runs `body` with every candidate set put to the reading step, as
/// `scripts/eval-sql-draft.sh` does with EVAL_READ=always. The default asks
/// only about a set too large to write from as it is.
@MainActor
private func askingAlways(_ body: () async -> Void) async {
    SQLDraftPipeline.readPolicy = .always
    defer { SQLDraftPipeline.readPolicy = .whenLarge }
    await body()
}

private func readJSON(_ uses: [(Key, [String])]) -> String {
    json(["plan": "p", "tables": uses.map { ["table": $0.0.description, "columns": $0.1] }])
}

@MainActor
private func testReadKeepsTheTablesTheModelNames() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.schemaAnswers = [readJSON([(orders, ["ID", "placed_at", "no_such_column"])])]
    backend.typedAnswers = [draftJSON("SELECT o.id FROM sales.orders o")]
    let catalog = threeTables()
    let definitions = Definitions.plain(catalog)
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: definitions.source)
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        do {
            let result = try await pipeline.draft("orders of each customer")
            expectEqual(result.tables, [orders], "read: only the table the model named goes to the draft")
            expectEqual(result.requests, 2, "read: one reading request and one draft")
        } catch {
            expect(false, "draft threw \(error)")
        }
        expectEqual(stages, [.finding, .reading, .writing, .checking], "read: named tables need no choosing")
        expectEqual(backend.requests.map(\.kind), [.schema, .typed], "read: the reading request, then the draft")
        expectEqual(definitions.asked, [[orders, customers]], "read: each candidate's DDL is asked for once")
        guard backend.requests.count == 2 else { return }
        let read = backend.requests[0], draft = backend.requests[1]
        expect(read.instructions.contains(SQLDraftPrompt.readInstructions), "read: its own instructions")
        expect(read.sampling == .greedy, "read: greedy")
        expect(read.prompt.contains("CREATE TABLE \"sales\".\"orders\"") && read.prompt.contains("CREATE TABLE \"sales\".\"customers\""),
               "read: the candidates' DDL is in the request")
        expect(read.prompt.contains("orders of each customer"), "read: and the analyst's sentence")
        expect(draft.instructions.contains(SQLDraftPrompt.ddlDraftInstructions), "draft: the DDL instructions go with a DDL block")
        expect(draft.prompt.contains("CREATE TABLE \"sales\".\"orders\"") && !draft.prompt.contains("\"customers\""),
               "draft: the kept table's DDL and not the dropped one's")
        // No request carries another request's answer.
        expect(!draft.prompt.contains("no_such_column") && !draft.instructions.contains("no_such_column"),
               "draft: the reading step's answer is not passed on")
    }
}

@MainActor
private func testSmallSetGoesStraightToTheDraft() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.typedAnswers = [draftJSON("SELECT o.id FROM sales.orders o")]
    let catalog = threeTables()
    let definitions = Definitions.plain(catalog)
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: definitions.source)
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        let result = try? await pipeline.draft("orders of each customer")
        expectEqual(result?.tables ?? [], [orders, customers], "small: every candidate goes to the draft")
        expectEqual(backend.requests.map(\.kind), [.typed], "small: one request, the draft")
        expectEqual(result?.requests ?? 0, 1, "small: and it is counted as one")
        expectEqual(stages, [.finding, .reading, .writing, .checking], "small: the DDL is still read from the database")
        expectEqual(definitions.asked, [[orders, customers]], "small: once")
        let draft = backend.requests.first
        expect(draft?.instructions.contains(SQLDraftPrompt.ddlDraftInstructions) == true, "small: the DDL instructions")
        expect(draft?.prompt.contains("CREATE TABLE \"sales\".\"orders\"") == true
               && draft?.prompt.contains("CREATE TABLE \"sales\".\"customers\"") == true, "small: both tables as DDL")
    }
}

@MainActor
private func testNoCandidateFitsSoTheModelChoosesAgain() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.schemaAnswers = [
        readJSON([]),                                       // orders and customers: neither
        json(["reason": "r", "tables": [regions.description]]),   // chosen from the other names
        readJSON([(regions, ["label"])]),                   // and it holds what was asked for
    ]
    backend.typedAnswers = [draftJSON("SELECT r.label FROM sales.regions r")]
    let catalog = threeTables()
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        let result = try? await pipeline.draft("orders by sales territory")
        expectEqual(result?.tables ?? [], [regions], "again: the second choice is what the draft is shown")
        expectEqual(stages, [.finding, .reading, .choosing, .reading, .writing, .checking], "again: choose and read once more")
        expectEqual(backend.requests.map(\.kind), [.schema, .schema, .schema, .typed], "again: four requests in all")
        guard backend.requests.count == 4 else { return }
        let choose = backend.requests[1]
        expect(choose.instructions.contains(SQLDraftPrompt.pickInstructions), "again: the choice is by name")
        expect(choose.prompt.contains("sales.regions") && !choose.prompt.contains("sales.orders:"),
               "again: from the names not yet read: \(choose.prompt)")
        expect(!choose.prompt.contains("CREATE TABLE"), "again: names, not DDL")
    }

    // Nothing anywhere: the best candidates still get a draft, once.
    let empty = FakeBackend()
    empty.contextSize = 8192
    empty.schemaAnswers = [readJSON([]), json(["reason": "r", "tables": [regions.description]]), readJSON([])]
    empty.typedAnswers = [draftJSON("SELECT o.id FROM sales.orders o")]
    await withBackend(empty) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        let result = try? await pipeline.draft("orders by sales territory")
        expect(result?.tables.isEmpty == false, "nothing kept: the draft is still written from the best candidates")
        expectEqual(empty.requests.count, 4, "nothing kept: and the model is not asked a third time")
    }
}

@MainActor
private func testFailedReadKeepsItsTables() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.schemaAnswers = [nil]
    backend.typedAnswers = [draftJSON("SELECT o.id FROM sales.orders o")]
    let catalog = threeTables()
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        do {
            let result = try await pipeline.draft("orders of each customer")
            expectEqual(result.tables, [orders, customers], "failed read: the tables it could not ask about are kept")
            expect(result.trace.contains { $0.hasPrefix("read failed") }, "failed read: and the trace says so")
        } catch {
            expect(false, "a failed read must not fail the draft: \(error)")
        }
    }
}

@MainActor
private func testWideTablesAreReadInSeveralSmallRequests() async {
    // The smallest budgets: 500 tokens of DDL to a reading request, 600 to
    // the draft. Each of these tables is about 300.
    let backend = FakeBackend()
    backend.contextSize = 0
    let wide = (1...40).map { "measure_\($0)" }
    let columns: [Key: [Source]] = [
        orders: [Source(name: "id", type: "bigint", isPrimaryKey: true)] + wide.map { Source(name: $0, type: "bigint", isPrimaryKey: false) },
        customers: [Source(name: "id", type: "bigint", isPrimaryKey: true)] + wide.map { Source(name: $0, type: "bigint", isPrimaryKey: false) },
    ]
    let catalog = DraftCatalog(columns: columns, facts: [:])
    let budget = SQLDraftPrompt.Budget(contextSize: 0)
    backend.schemaAnswers = [readJSON([(orders, ["measure_7"])]), readJSON([(customers, ["measure_9"])])]
    backend.typedAnswers = [draftJSON("SELECT o.measure_7 FROM sales.orders o")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        let result = try? await pipeline.draft("orders and customers")
        expectEqual((result?.tables ?? []).sorted(), [customers, orders], "wide: both tables are kept")
        expectEqual(backend.requests.map(\.kind), [.schema, .schema, .typed], "wide: two reading requests instead of one long one")
        guard backend.requests.count == 3 else { return }
        for read in backend.requests.prefix(2) {
            let block = read.prompt.components(separatedBy: "\n\nRequest:").first ?? ""
            expect(SQLDraftPrompt.estimateTokens(block) <= budget.readBlock + 10,
                   "wide: each reading request is inside its budget: \(SQLDraftPrompt.estimateTokens(block))")
        }
        let draft = backend.requests[2]
        expect(draft.instructions.contains(SQLDraftPrompt.draftInstructions) && !draft.prompt.contains("CREATE TABLE"),
               "wide: the DDL of both is too much for the draft, which gets the compact block")
        expect(draft.prompt.contains("measure_7") && draft.prompt.contains("measure_9"),
               "wide: with the columns the reading step named")
        let block = draft.prompt.components(separatedBy: "\n\nRequest:").first ?? ""
        expect(SQLDraftPrompt.estimateTokens(block) <= budget.draftBlock + 10,
               "wide: and inside the draft's budget: \(SQLDraftPrompt.estimateTokens(block))")
    }
}

@MainActor
private func testPartitionIsReadAsItsParent() async {
    let events = Key(schema: "sales", name: "events")
    let events2024 = Key(schema: "sales", name: "events_2024")
    let columns: [Key: [Source]] = [
        events: [Source(name: "id", type: "bigint", isPrimaryKey: true), Source(name: "at", type: "date", isPrimaryKey: false)],
        events2024: [Source(name: "id", type: "bigint", isPrimaryKey: true), Source(name: "at", type: "date", isPrimaryKey: false)],
        regions: [Source(name: "code", type: "text", isPrimaryKey: true)],
    ]
    let parentDDL = "CREATE TABLE \"sales\".\"events\" (\n    \"id\" bigint,\n    \"at\" date\n) PARTITION BY RANGE (at);"
    let childDDL = "CREATE TABLE \"sales\".\"events_2024\" (\n    \"id\" bigint\n);\n\nALTER TABLE \"sales\".\"events\" ATTACH PARTITION \"sales\".\"events_2024\"\n    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');"
    let definitions = Definitions([
        events: .init(ddl: parentDDL, partitionOf: nil),
        events2024: .init(ddl: childDDL, partitionOf: events),
        regions: .init(ddl: ddl(regions, ["code"]), partitionOf: nil),
    ])

    // The cache knows it is a partition: it is never a candidate.
    var flagged = DraftCatalog(columns: columns, facts: [:])
    flagged.partitions = [events2024]
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.typedAnswers = [draftJSON("SELECT e.id FROM sales.events e")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: flagged, defaultSchema: "sales", definitions: definitions.source)
        let result = try? await pipeline.draft("events this year")
        expectEqual(result?.tables ?? [], [events], "partition: the parent stands for its partitions")
        expectEqual(definitions.asked, [[events]], "partition: a partition's DDL is not even read")
        let prompt = backend.requests.first?.prompt ?? ""
        expect(prompt.contains("PARTITION BY RANGE (at)") && !prompt.contains("events_2024"), "partition: the parent's DDL is what is shown")
    }

    // The cache does not know: the definition says so, and the parent is read in its place.
    let unflagged = DraftCatalog(columns: [events2024: columns[events2024]!, events: columns[events]!], facts: [:])
    let second = FakeBackend()
    second.contextSize = 8192
    second.typedAnswers = [draftJSON("SELECT e.id FROM sales.events e")]
    await withBackend(second) {
        let pipeline = SQLDraftPipeline(catalog: unflagged, defaultSchema: "sales", definitions: definitions.source)
        let result = try? await pipeline.draft("events_2024 rows")
        expectEqual(result?.tables ?? [], [events], "partition: one the request names is read as its parent")
        for request in second.requests {
            expect(!request.prompt.contains("ATTACH PARTITION") && !request.prompt.contains("2024-01-01"),
                   "partition: its bounds reach no request")
        }
    }
}

@MainActor
private func testManyMatchesAreChosenByNameBeforeAnyDDLIsRead() async {
    // Twelve tables that all match "invoice": more than are read.
    var columns: [Key: [Source]] = [:]
    let keys = (1...12).map { Key(schema: "sales", name: "invoice_part_\($0)") }
    for key in keys { columns[key] = [Source(name: "id", type: "bigint", isPrimaryKey: true)] }
    let catalog = DraftCatalog(columns: columns, facts: [:])
    let definitions = Definitions.plain(catalog)
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.schemaAnswers = [
        json(["reason": "r", "tables": [keys[2].description, keys[4].description]]),
        readJSON([(keys[4], ["id"])]),
    ]
    backend.typedAnswers = [draftJSON("SELECT p.id FROM sales.invoice_part_5 p")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: definitions.source)
        let result = try? await pipeline.draft("invoice totals")
        expectEqual(result?.tables ?? [], [keys[4]], "many: chosen by name, then read")
        expectEqual(definitions.asked, [[keys[2], keys[4]]], "many: only the chosen tables' DDL is read")
        let choose = backend.requests.first
        expect(choose?.prompt.contains("CREATE TABLE") == false, "many: the first request holds names, not DDL")
        expectEqual(result?.requests ?? 0, 3, "many: choose, read, write")
    }
}

@MainActor
private func testADraftIsSixRequestsAtMost() async {
    // Five wide tables, each about 300 tokens of DDL against a 500-token
    // reading budget: one table to a request, and only three requests.
    let backend = FakeBackend()
    backend.contextSize = 0
    let wide = (1...40).map { "measure_\($0)" }
    var columns: [Key: [Source]] = [:]
    let keys = (1...5).map { Key(schema: "sales", name: "ledger_\($0)") }
    for key in keys {
        columns[key] = [Source(name: "id", type: "bigint", isPrimaryKey: true)]
            + wide.map { Source(name: $0, type: "bigint", isPrimaryKey: false) }
    }
    let catalog = DraftCatalog(columns: columns, facts: [:])
    backend.schemaAnswers = [readJSON([]), readJSON([]), readJSON([])]
    backend.typedAnswers = [draftJSON("SELECT l.nothing FROM sales.ledger_4 l"), draftJSON("SELECT l.id FROM sales.ledger_4 l")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        let result = try? await pipeline.draft("ledger totals")
        expectEqual(backend.requests.map(\.kind), [.schema, .schema, .schema, .typed, .typed],
                    "limit: three reading requests, the draft and its repair")
        expectEqual((result?.tables ?? []).count, 2, "limit: the tables past the third request are kept without being asked about")
        expect((result?.requests ?? 99) <= 6, "limit: never more than six requests")
    }
}

// MARK: - Over a custom endpoint

/// An OpenAI-compatible endpoint in memory: records each request's body and
/// answers from a queue, as HTTP.
@MainActor
private final class FakeEndpoint {
    enum Reply {
        /// 200 with this JSON object as the message's content.
        case answer(String)
        case status(Int)
    }

    var replies: [Reply] = []
    private(set) var bodies: [[String: Any]] = []
    private(set) var texts: [String] = []

    func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = request.httpBody ?? Data()
        texts.append(String(decoding: data, as: UTF8.self))
        bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        let reply = replies.isEmpty ? Reply.status(500) : replies.removeFirst()
        let (status, body): (Int, String)
        switch reply {
        case .answer(let content):
            status = 200
            body = json(["choices": [["message": ["role": "assistant", "content": content], "finish_reason": "stop"]]])
        case .status(let code):
            (status, body) = (code, "{}")
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func backend(contextSize: Int = 32_768) -> EndpointIntelligenceBackend {
        EndpointIntelligenceBackend(
            base: URL(string: "http://localhost:1234/v1")!, model: "local-model", contextSize: contextSize,
            key: { nil }, transport: { [self] in try await transport($0) })
    }

    func system(_ index: Int) -> String {
        ((bodies[index]["messages"] as? [[String: String]]) ?? []).first { $0["role"] == "system" }?["content"] ?? ""
    }

    func user(_ index: Int) -> String {
        ((bodies[index]["messages"] as? [[String: String]]) ?? []).first { $0["role"] == "user" }?["content"] ?? ""
    }

    func schema(_ index: Int) -> [String: Any] {
        (((bodies[index]["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]) ?? [:]
    }
}

/// Twelve tables that all match "invoice", so every step runs: choose by
/// name, read, write.
private func invoiceCatalog() -> (catalog: DraftCatalog, keys: [Key]) {
    var columns: [Key: [Source]] = [:]
    let keys = (1...12).map { Key(schema: "sales", name: "invoice_part_\($0)") }
    for key in keys {
        columns[key] = [Source(name: "id", type: "bigint", isPrimaryKey: true), Source(name: "total", type: "numeric", isPrimaryKey: false)]
    }
    return (DraftCatalog(columns: columns, facts: [:]), keys)
}

@MainActor
private func testEveryStepGoesOverACustomEndpoint() async {
    let (catalog, keys) = invoiceCatalog()
    let endpoint = FakeEndpoint()
    endpoint.replies = [
        // A model that shows its reasoning and fences its answer is still read.
        .answer("<think>which tables?</think>```json\n" + json(["reason": "r", "tables": [keys[2].description, keys[4].description]]) + "\n```"),
        .answer(readJSON([(keys[4], ["id", "total"])])),
        .answer(draftJSON("SELECT p.id, p.total FROM sales.invoice_part_5 p")),
    ]
    IntelligenceBackends.overrideForTesting = endpoint.backend()
    defer { IntelligenceBackends.overrideForTesting = nil }
    await askingAlways {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        do {
            let result = try await pipeline.draft("invoice totals")
            expectEqual(result.sql, "SELECT p.id, p.total FROM sales.invoice_part_5 p", "endpoint: the draft comes back")
            expectEqual(result.tables, [keys[4]], "endpoint: from the table the endpoint chose and then kept")
            expectEqual(result.requests, 3, "endpoint: choose, read, write")
            expect(!result.trace.contains { $0.hasPrefix("prompt tokens") },
                   "endpoint: it cannot count tokens, so the estimate decides what fits")
        } catch {
            expect(false, "endpoint: draft threw \(error)")
        }
    }
    guard endpoint.bodies.count == 3 else {
        expect(false, "endpoint: three requests were expected, got \(endpoint.bodies.count)")
        return
    }
    for index in 0..<3 {
        expectEqual(endpoint.bodies[index]["model"] as? String, "local-model", "endpoint: request \(index + 1) names the model")
        expectEqual(endpoint.bodies[index]["temperature"] as? Int, 0, "endpoint: request \(index + 1) is greedy")
        expectEqual((endpoint.bodies[index]["response_format"] as? [String: Any])?["type"] as? String, "json_schema",
                    "endpoint: request \(index + 1) asks for the schema")
        expect(endpoint.system(index).hasPrefix(IntelligenceInstructions.sqlSafety), "endpoint: request \(index + 1) leads with the safety sentences")
        expect(endpoint.user(index).contains("invoice totals"), "endpoint: request \(index + 1) carries the analyst's sentence")
    }

    // Choose: names in the prompt, the same names as the only allowed answers.
    let pickItems = ((endpoint.schema(0)["properties"] as? [String: Any])?["tables"] as? [String: Any])?["items"] as? [String: Any]
    expectEqual(Set(pickItems?["enum"] as? [String] ?? []), Set(keys.map(\.description)), "endpoint: the choice is held to the listed names")
    expect(!endpoint.user(0).contains("CREATE TABLE"), "endpoint: the first request holds names, not DDL")

    // Read: DDL of the two chosen tables; the answer's shape as a definition.
    expect(endpoint.user(1).contains("CREATE TABLE \"sales\".\"invoice_part_3\"")
           && endpoint.user(1).contains("CREATE TABLE \"sales\".\"invoice_part_5\""), "endpoint: the reading request holds the chosen tables' DDL")
    expect(!endpoint.user(1).contains("invoice_part_7"), "endpoint: and no other table's")
    let use = (endpoint.schema(1)["$defs"] as? [String: Any])?["TableUse"] as? [String: Any]
    expectEqual(((use?["properties"] as? [String: Any])?["table"] as? [String: Any])?["enum"] as? [String] ?? [],
                [keys[2].description, keys[4].description], "endpoint: the reading answer is held to those two names")
    let tableAt = endpoint.texts[1].range(of: "\"table\":")?.lowerBound
    let columnsAt = endpoint.texts[1].range(of: "\"columns\":")?.lowerBound
    expect(tableAt != nil && columnsAt != nil && tableAt! < columnsAt!, "endpoint: a table is named before its columns")

    // Write: the kept table's DDL, and plan before sql before note.
    expect(endpoint.user(2).contains("CREATE TABLE \"sales\".\"invoice_part_5\"") && !endpoint.user(2).contains("invoice_part_3"),
           "endpoint: the writing request holds only the kept table")
    expect(endpoint.system(2).contains(SQLDraftPrompt.ddlDraftInstructions), "endpoint: with the DDL instructions")
    let order = ["plan", "sql", "note"].compactMap { name in endpoint.texts[2].range(of: "\"\(name)\":{").map { (name, $0.lowerBound) } }
        .sorted { $0.1 < $1.1 }.map(\.0)
    expectEqual(order, ["plan", "sql", "note"], "endpoint: the draft's fields are asked for in the order they are meant to be written")

    // Each one-line field is held to a line, so a model that starts
    // repeating itself inside one is stopped after a line's worth.
    func limit(_ request: Int, _ field: String) -> Int? {
        ((endpoint.schema(request)["properties"] as? [String: Any])?[field] as? [String: Any])?["maxLength"] as? Int
    }
    expectEqual(limit(0, "reason"), SQLDraftPipeline.lineLimit, "endpoint: the choice's reason is held to a line")
    expectEqual(limit(1, "plan"), SQLDraftPipeline.lineLimit, "endpoint: the reading's plan is held to a line")
    let columnNames = ((use?["properties"] as? [String: Any])?["columns"] as? [String: Any])?["items"] as? [String: Any]
    expectEqual(columnNames?["maxLength"] as? Int, SQLDraftPipeline.nameLimit, "endpoint: a column name is held to a name's length")
    expectEqual(limit(2, "plan"), SQLDraftPipeline.lineLimit, "endpoint: the draft's plan is held to a line")
    expectEqual(limit(2, "note"), SQLDraftPipeline.lineLimit, "endpoint: and so is its note")
    expectEqual(limit(2, "sql"), SQLDraftPipeline.statementLimit, "endpoint: the statement is held to a statement's length")
}

@MainActor
private func testAStatementThatRanOnGoesToRepair() async {
    // What an endpoint returns when its model repeats itself inside the
    // statement: the field, closed at its limit.
    let looped = "SELECT o.id FROM sales.orders o WHERE o.id IN (" + String(repeating: "1, ", count: 700)
    let cut = String(looped.prefix(SQLDraftPipeline.statementLimit))
    let backend = FakeBackend()
    backend.typedAnswers = [draftJSON(cut), draftJSON("SELECT o.id FROM sales.orders o")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        let result = try? await pipeline.draft("orders")
        expectEqual(result?.sql ?? "", "SELECT o.id FROM sales.orders o", "cut off: the repaired statement replaces the one that ran on")
        expectEqual(result?.problems ?? ["?"], [], "cut off: and nothing is left to report")
        expect(stages.contains(.repairing), "cut off: a statement at the limit starts a repair")
        expect(backend.requests.last?.prompt.contains("probably cut off") == true, "cut off: the repair is told why")
    }

    // The repair runs on too: the draft is kept, and the analyst is told.
    let stuck = FakeBackend()
    stuck.typedAnswers = [draftJSON(cut), draftJSON(cut)]
    await withBackend(stuck) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("orders")
        expectEqual(result?.problems.first ?? "", SQLDraftPipeline.cutOffProblem(), "cut off: a draft still cut off says so")
        expectEqual(stuck.requests.count, 2, "cut off: one draft and one repair, no more")
    }

    // A statement of ordinary length is not suspected.
    let ordinary = FakeBackend()
    ordinary.typedAnswers = [draftJSON("SELECT o.id FROM sales.orders o")]
    await withBackend(ordinary) {
        let result = try? await SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales").draft("orders")
        expectEqual(ordinary.requests.count, 1, "ordinary: no repair")
        expectEqual(result?.problems ?? ["?"], [], "ordinary: no problem")
    }
}

@MainActor
private func testAnEndpointThatRefusesSchemasStillDrafts() async {
    let (catalog, keys) = invoiceCatalog()
    let endpoint = FakeEndpoint()
    endpoint.replies = [
        .status(400),                                                // json_schema refused
        .answer(json(["reason": "r", "tables": [keys[0].description]])),   // json_object accepted
        .answer(draftJSON("SELECT p.id FROM sales.invoice_part_1 p")),
    ]
    IntelligenceBackends.overrideForTesting = endpoint.backend()
    defer { IntelligenceBackends.overrideForTesting = nil }
    let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
    let result = try? await pipeline.draft("invoice totals")
    expectEqual(result?.sql ?? "", "SELECT p.id FROM sales.invoice_part_1 p", "plainer: the draft still comes back")
    expectEqual(endpoint.bodies.count, 3, "plainer: one refusal, then choose and write")
    guard endpoint.bodies.count == 3 else { return }
    expectEqual((endpoint.bodies[1]["response_format"] as? [String: Any])?["type"] as? String, "json_object", "plainer: the next way down")
    expect(endpoint.system(1).contains("JSON Schema") && endpoint.system(1).contains(keys[0].description),
           "plainer: the allowed names are written into the instructions instead")
    expectEqual((endpoint.bodies[2]["response_format"] as? [String: Any])?["type"] as? String, "json_object",
                "plainer: and the way that worked is used for the rest of the draft")
}

@MainActor
private func testAnEndpointFailureInAStepDoesNotLoseTheDraft() async {
    let (catalog, keys) = invoiceCatalog()

    // The choice fails (the endpoint is over its limit): the best matches stand in.
    let busy = FakeEndpoint()
    busy.replies = [.status(429), .answer(draftJSON("SELECT p.id FROM sales.invoice_part_1 p"))]
    IntelligenceBackends.overrideForTesting = busy.backend()
    var result = try? await SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        .draft("invoice totals")
    expect(result?.sql.isEmpty == false, "busy: a refused choice does not fail the draft")
    expect(result?.trace.contains { $0.hasPrefix("pick failed") } == true, "busy: and the trace says what happened")

    // The answer is not JSON at all: same.
    let chatty = FakeEndpoint()
    chatty.replies = [.answer("I think you want the invoices."), .answer(draftJSON("SELECT p.id FROM sales.invoice_part_1 p"))]
    IntelligenceBackends.overrideForTesting = chatty.backend()
    result = try? await SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        .draft("invoice totals")
    expect(result?.sql.isEmpty == false, "chatty: an answer that is not JSON does not fail the draft")

    // The writing request fails: that IS the draft, and the error reaches the strip.
    let down = FakeEndpoint()
    down.replies = [.answer(json(["reason": "r", "tables": [keys[0].description]])), .status(401)]
    IntelligenceBackends.overrideForTesting = down.backend()
    do {
        _ = try await SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
            .draft("invoice totals")
        expect(false, "down: a refused key must fail the draft")
    } catch {
        expectEqual(error as? IntelligenceEndpointError, .keyRefused, "down: the endpoint's own error is passed on")
    }
    IntelligenceBackends.overrideForTesting = nil
}

@MainActor
private func testAHugeWindowIsSentNoMoreThanTheCeilings() async {
    // Eight tables of about 800 tokens of DDL each: far more than a draft
    // needs, and a 200,000-token window would hold all of it.
    let wide = (1...100).map { "measurement_value_\($0)" }
    var columns: [Key: [Source]] = [:]
    let keys = (1...8).map { Key(schema: "sales", name: "ledger_\($0)") }
    for key in keys {
        columns[key] = [Source(name: "id", type: "bigint", isPrimaryKey: true)] + wide.map { Source(name: $0, type: "bigint", isPrimaryKey: false) }
    }
    let catalog = DraftCatalog(columns: columns, facts: [:])
    let endpoint = FakeEndpoint()
    endpoint.replies = [
        .answer(readJSON([(keys[0], ["id"])])), .answer(readJSON([])), .answer(readJSON([])),
        .answer(draftJSON("SELECT l.id FROM sales.ledger_1 l")),
    ]
    IntelligenceBackends.overrideForTesting = endpoint.backend(contextSize: 200_000)
    defer { IntelligenceBackends.overrideForTesting = nil }
    let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
    let result = try? await pipeline.draft("ledger totals")
    expect(result?.sql.isEmpty == false, "huge: the draft comes back")
    let budget = SQLDraftPrompt.Budget(contextSize: 200_000)
    for (index, text) in endpoint.texts.enumerated() {
        let tokens = SQLDraftPrompt.estimateTokens(endpoint.user(index))
        expect(tokens <= SQLDraftPrompt.Budget.draftCeiling + 100,
               "huge: request \(index + 1) is about \(tokens) tokens, under the ceiling, in a window of 200,000")
        expect(text.utf8.count < 40_000, "huge: and under 40 kB on the wire")
    }
    expect(endpoint.bodies.count >= 3, "huge: the tables are read in parts rather than at once: \(endpoint.bodies.count) requests")
    expect(endpoint.bodies.count <= 6, "huge: and in no more than six requests")
    expect(budget.readBlock == SQLDraftPrompt.Budget.readBlockCeiling, "huge: the reading budget is its ceiling, not a share of 200,000")
}

// MARK: - Changing a statement

private let paidOrders = "SELECT o.id FROM sales.orders o WHERE o.id > 5"

@MainActor
private func testAChangeCarriesTheStatementAndItsTables() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    let changed = paidOrders + " AND o.placed_at >= now() - interval '30 days'"
    backend.schemaAnswers = [draftJSON(changed)]
    let catalog = threeTables()
    let definitions = Definitions.plain(catalog)
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: definitions.source)
        var stages: [SQLDraftPipeline.Stage] = []
        pipeline.onStage = { stages.append($0) }
        let result = try? await pipeline.draft("only the last 30 days", adjusting: paidOrders + ";\n")
        expectEqual(result?.sql ?? "", changed, "change: the answer is the changed statement")
        expectEqual(result?.tables ?? [], [orders], "change: the statement's own table is shown, and no other")
        expectEqual(result?.problems ?? ["?"], [], "change: clean")
        expectEqual(stages, [.finding, .reading, .writing, .checking], "change: no choosing among names")
        expectEqual(backend.requests.count, 1, "change: one request")
        let request = backend.requests.first
        expect(request?.instructions.contains(SQLDraftPrompt.ddlAdjustInstructions) == true, "change: the adjusting instructions")
        expect(request?.instructions.hasPrefix(IntelligenceInstructions.sqlSafety) == true, "change: after the safety sentences")
        expect(request?.prompt.contains("Current query:\n\(paidOrders);\n\nRequest:") == true, "change: the prompt carries the statement, trimmed")
        expect(request?.prompt.hasSuffix("Request: only the last 30 days") == true, "change: and the change last")
        expect(request?.prompt.contains("CREATE TABLE \"sales\".\"orders\"") == true
               && request?.prompt.contains("regions") == false, "change: the DDL of what it reads only")
    }
}

@MainActor
private func testAChangeCanAddATable() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    backend.schemaAnswers = [draftJSON("SELECT o.id, c.name FROM sales.orders o JOIN sales.customers c ON c.id = o.customer_id WHERE o.id > 5")]
    let catalog = threeTables()
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        let result = try? await pipeline.draft("add the name of the customer", adjusting: paidOrders)
        expectEqual(result?.tables ?? [], [orders, customers], "add: the statement's table first, then the one the change names")
        expectEqual(result?.reads ?? [], [orders, customers], "add: and the changed statement reads both")
    }
}

@MainActor
private func testAChangeWithoutDDLKeepsTheStatementsColumns() async {
    let backend = FakeBackend()
    backend.schemaAnswers = [draftJSON(paidOrders + " LIMIT 10")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("the first ten", adjusting: paidOrders)
        expectEqual(result?.sql ?? "", paidOrders + " LIMIT 10", "compact: changed")
        let request = backend.requests.first
        expect(request?.instructions.contains(SQLDraftPrompt.adjustInstructions) == true, "compact: the adjusting instructions for the compact block")
        expect(request?.prompt.contains("sales.orders\n") == true && request?.prompt.contains("Current query:") == true,
               "compact: the block and the statement")
    }
}

@MainActor
private func testAnUnchangedStatementIsAFailure() async {
    let backend = FakeBackend()
    backend.schemaAnswers = [draftJSON("SELECT o.id\nFROM sales.orders o   WHERE o.id > 5;")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            _ = try await pipeline.draft("make it better", adjusting: paidOrders)
            expect(false, "unchanged: must throw")
        } catch {
            expectEqual(error as? SQLDraftPipeline.Failure, .unchanged, "unchanged: said, not offered as a new version")
        }
        expectEqual(backend.requests.count, 1, "unchanged: and not sent to a repair")
    }
}

@MainActor
private func testAStatementTooLongForTheWindowIsNotSent() async {
    let backend = FakeBackend()
    let long = "SELECT o.id FROM sales.orders o WHERE o.id IN (" + (1...700).map(String.init).joined(separator: ", ") + ")"
    expect(long.count > SQLDraftPipeline.adjustLimit(contextSize: 4096)
           && long.count < SQLDraftPipeline.adjustLimit(contextSize: 8192), "too long: (the fixture sits between the two windows)")
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        do {
            _ = try await pipeline.draft("newest first", adjusting: long)
            expect(false, "too long: must throw")
        } catch {
            expectEqual(error as? SQLDraftPipeline.Failure, .statementTooLong, "too long: refused before anything is sent")
        }
        expectEqual(backend.requests.count, 0, "too long: nothing was sent")
    }
    let wider = FakeBackend()
    wider.contextSize = 8192
    wider.schemaAnswers = [draftJSON(long + " ORDER BY o.id DESC")]
    await withBackend(wider) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("newest first", adjusting: long)
        expectEqual(result?.problems ?? ["?"], [], "longer window: a statement longer than a draft's limit is not called cut off")
    }
}

@MainActor
private func testTheAnalystsOwnNamesAreNotRepaired() async {
    let backend = FakeBackend()
    let own = "SELECT o.nope FROM sales.orders o"
    backend.schemaAnswers = [draftJSON(own + " LIMIT 5")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        expect(!SQLDraftChecker.check(own, in: smallCatalog(), defaultSchema: "sales").isEmpty, "own: (the fixture has a problem)")
        let result = try? await pipeline.draft("the first five", adjusting: own)
        expectEqual(result?.sql ?? "", own + " LIMIT 5", "own: the statement is changed as asked")
        expectEqual(result?.problems ?? ["?"], [], "own: a name the analyst wrote is not reported")
        expectEqual(backend.requests.count, 1, "own: nor sent to a repair")
    }
}

@MainActor
private func testATableNobodyAskedForIsSentBack() async {
    let backend = FakeBackend()
    backend.contextSize = 8192
    let joined = "SELECT o.id FROM sales.orders o JOIN sales.customers c ON c.id = o.customer_id WHERE o.id > 5 AND o.id < 9"
    backend.schemaAnswers = [draftJSON(joined), draftJSON(paidOrders + " AND o.id < 9")]
    let catalog = threeTables()
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales", definitions: Definitions.plain(catalog).source)
        let result = try? await pipeline.draft("and under 9", adjusting: paidOrders)
        expectEqual(backend.requests.count, 2, "unasked: a join the request did not ask for goes to a repair")
        expect(backend.requests.last?.prompt.contains("now reads sales.customers, which the request did not ask for") == true,
               "unasked: which names the table")
        expectEqual(result?.sql ?? "", paidOrders + " AND o.id < 9", "unasked: and the repair is kept")
        expectEqual(result?.problems ?? ["?"], [], "unasked: clean")
    }
    // A repair that keeps the join: the analyst is told.
    let stubborn = FakeBackend()
    stubborn.schemaAnswers = [draftJSON(joined), draftJSON(joined)]
    await withBackend(stubborn) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales")
        let result = try? await pipeline.draft("and under 9", adjusting: paidOrders)
        expectEqual(result?.problems.count ?? 0, 1, "unasked: a join that stays is said under the draft")
    }
    // A table the request names is asked for.
    let named = FakeBackend()
    named.schemaAnswers = [draftJSON(joined)]
    await withBackend(named) {
        let pipeline = SQLDraftPipeline(catalog: catalog, defaultSchema: "sales")
        let result = try? await pipeline.draft("only customers that exist", adjusting: paidOrders)
        expectEqual(result?.problems ?? ["?"], [], "unasked: a table the request names is not reported")
        expectEqual(named.requests.count, 1, "unasked: nor repaired")
    }
}

@MainActor
private func testAChangeIsRepairedAsAChange() async {
    let backend = FakeBackend()
    let bad = paidOrders + " AND o.bogus_column = 1"
    backend.schemaAnswers = [draftJSON(bad), draftJSON(paidOrders + " AND o.customer_id = 1")]
    await withBackend(backend) {
        let pipeline = SQLDraftPipeline(catalog: smallCatalog(), defaultSchema: "sales")
        let result = try? await pipeline.draft("only customer 1", adjusting: paidOrders)
        expectEqual(result?.sql ?? "", paidOrders + " AND o.customer_id = 1", "repair: the corrected statement")
        expectEqual(backend.requests.count, 2, "repair: one change and one repair")
        let repair = backend.requests.last
        expect(repair?.prompt.contains("Current query:\n\(bad)\n") == true, "repair: the draft is the query to change")
        expect(repair?.prompt.contains("correct these errors and change nothing else") == true
               && repair?.prompt.contains("bogus_column") == true, "repair: and the change is to correct it")
        expect(repair?.instructions.contains(SQLDraftPrompt.adjustInstructions) == true, "repair: under the adjusting instructions")
    }
}

func runTests() {
    Task { @MainActor in
        await testDraftGoesThroughTheBackend()
        await testDialectReachesTheInstructions()
        await testBackendIsFixedForOneDraft()
        await testDraftCarriesNoInvisibleCharacters()
        await testEmptyAnswerIsAFailure()
        await testBackendErrorIsPassedOn()
        await testRepairAsksOnceMore()
        await testFailedRepairKeepsTheDraft()
        await testPickIsHeldToTheList()
        await testFailedPickFallsBack()
        await testTokenCountShrinksTheBlock()
        await askingAlways { await testReadKeepsTheTablesTheModelNames() }
        await testSmallSetGoesStraightToTheDraft()
        await askingAlways { await testNoCandidateFitsSoTheModelChoosesAgain() }
        await askingAlways { await testFailedReadKeepsItsTables() }
        await testWideTablesAreReadInSeveralSmallRequests()
        await testPartitionIsReadAsItsParent()
        await testADraftIsSixRequestsAtMost()
        await testEveryStepGoesOverACustomEndpoint()
        await testAStatementThatRanOnGoesToRepair()
        await testAnEndpointThatRefusesSchemasStillDrafts()
        await testAnEndpointFailureInAStepDoesNotLoseTheDraft()
        await testAHugeWindowIsSentNoMoreThanTheCeilings()
        await askingAlways { await testManyMatchesAreChosenByNameBeforeAnyDDLIsRead() }
        await testAChangeCarriesTheStatementAndItsTables()
        await testAChangeCanAddATable()
        await testAChangeWithoutDDLKeepsTheStatementsColumns()
        await testAnUnchangedStatementIsAFailure()
        await testAStatementTooLongForTheWindowIsNotSent()
        await testTheAnalystsOwnNamesAreNotRepaired()
        await testAChangeIsRepairedAsAChange()
        await testATableNobodyAskedForIsSentBack()
        print("\(passes) passed, \(failures) failed")
        exit(failures > 0 ? 1 : 0)
    }
    dispatchMain()
}
