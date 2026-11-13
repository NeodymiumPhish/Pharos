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
        print("\(passes) passed, \(failures) failed")
        exit(failures > 0 ? 1 : 0)
    }
    dispatchMain()
}
