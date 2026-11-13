// Adapter for the multi-step pipeline in the working tree. The catalogue is
// built the way the app builds it: the cache's information_schema columns,
// with the facts query's answer for each schema laid over them.
//
// With EVAL_ENDPOINT set (the script's `endpoint` mode) the pipeline asks a
// custom AI endpoint through the app's own client instead of the on-device
// model. The address passes the same rules as in Settings ▸ Intelligence.
import Foundation
import FoundationModels

/// Installs the endpoint backend once, before the first draft. A bad address
/// stops the run: scoring the on-device model under an endpoint's name would
/// be worse than no score.
@MainActor
private let endpointIsInstalled: Bool = {
    let env = ProcessInfo.processInfo.environment
    guard let address = env["EVAL_ENDPOINT"], !address.isEmpty else { return false }
    let model = (env["EVAL_ENDPOINT_MODEL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { fatalError("EVAL_ENDPOINT_MODEL is not set") }
    let base: URL
    switch IntelligenceEndpoint.baseURL(from: address) {
    case .success(let url): base = url
    case .failure(let problem): fatalError("EVAL_ENDPOINT: \(problem.message)")
    }
    let contextSize = Int(env["EVAL_ENDPOINT_CONTEXT"] ?? "") ?? 8192
    let key = env["EVAL_ENDPOINT_KEY"]
    // EVAL_ENDPOINT_LOG: every request and answer, as sent and received, for
    // finding out why an endpoint's answer was not read.
    var transport: EndpointIntelligenceBackend.Transport?
    if let path = env["EVAL_ENDPOINT_LOG"], !path.isEmpty {
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = IntelligenceEndpoint.makeSession()
        transport = { request in
            let (data, response) = try await session.data(for: request)
            if let log = FileHandle(forWritingAtPath: path) {
                log.seekToEndOfFile()
                log.write(Data("\n>>> ".utf8) + (request.httpBody ?? Data()) + Data("\n<<< ".utf8) + data + Data("\n".utf8))
                try? log.close()
            }
            return (data, response as! HTTPURLResponse)
        }
    }
    IntelligenceBackends.overrideForTesting = EndpointIntelligenceBackend(
        base: base, model: model, contextSize: contextSize, key: { key }, transport: transport)
    let place = IntelligenceEndpoint.isOnThisMac(base) ? "on this Mac" : "at \(IntelligenceEndpoint.host(of: base))"
    print("model: \(model) \(place), context \(contextSize) tokens, \(key?.isEmpty == false ? "with" : "without") an API key")
    return true
}()

/// A backend that budgets as if its window were smaller than it is. The
/// model, and so its real window, is the wrapped backend's.
@MainActor
private final class NarrowedBackend: IntelligenceBackend {
    private let base: IntelligenceBackend
    let contextSize: Int

    init(_ base: IntelligenceBackend, contextSize: Int) {
        self.base = base
        self.contextSize = contextSize
    }

    func respond<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type, sampling: IntelligenceSampling
    ) async throws -> Answer {
        try await base.respond(instructions: instructions, prompt: prompt, generating: type, sampling: sampling)
    }

    func respond(
        instructions: String, prompt: String, schema: GenerationSchema, sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        try await base.respond(instructions: instructions, prompt: prompt, schema: schema, sampling: sampling)
    }

    func respond(
        instructions: String, prompt: String, schema: GenerationSchema, textLimits: [String: Int],
        sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        try await base.respond(
            instructions: instructions, prompt: prompt, schema: schema, textLimits: textLimits, sampling: sampling)
    }

    func streamResponse<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type
    ) -> AsyncThrowingStream<Answer.PartiallyGenerated, Error> {
        base.streamResponse(instructions: instructions, prompt: prompt, generating: type)
    }

    func tokenCount(instructions: String, prompt: String, schema: GenerationSchema) async throws -> Int {
        try await base.tokenCount(instructions: instructions, prompt: prompt, schema: schema)
    }
}

/// EVAL_READ and EVAL_CONTEXT, applied once.
@MainActor
private let switchesAreSet: Bool = {
    let env = ProcessInfo.processInfo.environment
    if let raw = env["EVAL_READ"], !raw.isEmpty {
        guard let policy = SQLDraftPipeline.ReadPolicy(rawValue: raw) else { fatalError("EVAL_READ: unknown policy \(raw)") }
        SQLDraftPipeline.readPolicy = policy
    }
    if let raw = env["EVAL_CONTEXT"], let size = Int(raw) {
        let base = IntelligenceBackends.current
        guard size <= base.contextSize else { fatalError("EVAL_CONTEXT is larger than the model's window, \(base.contextSize)") }
        IntelligenceBackends.overrideForTesting = NarrowedBackend(base, contextSize: size)
    }
    print("window \(IntelligenceBackends.current.contextSize) tokens, read policy \(SQLDraftPipeline.readPolicy.rawValue), "
        + (env["EVAL_DDL_FILE"] == nil ? "no DDL" : "with DDL"))
    return true
}()

/// The fixture tables' DDL, written by eval-sql-draft.sh; nil with EVAL_DDL=0.
private let definitions: [DraftCatalog.TableKey: DraftCatalog.Definition]? = {
    guard let path = ProcessInfo.processInfo.environment["EVAL_DDL_FILE"] else { return nil }
    struct Row: Decodable { let ddl: String }
    let rows = try! JSONDecoder().decode([String: Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var out: [DraftCatalog.TableKey: DraftCatalog.Definition] = [:]
    for (name, row) in rows {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        out[DraftCatalog.TableKey(schema: parts[0], name: parts[1])] = DraftCatalog.Definition(ddl: row.ddl, partitionOf: nil)
    }
    return out
}()

@MainActor
func evalDraft(_ c: EvalCase, catalog: EvalCatalog) async throws -> EvalOutput {
    _ = endpointIsInstalled
    _ = switchesAreSet
    let factsPath = ProcessInfo.processInfo.environment["EVAL_FACTS"]!
    let facts = try JSONDecoder().decode(
        [String: SchemaDraftFacts].self, from: Data(contentsOf: URL(fileURLWithPath: factsPath)))
    var columns: [DraftCatalog.TableKey: [DraftCatalog.SourceColumn]] = [:]
    for row in catalog.columns.sorted(by: { $0.ordinal < $1.ordinal }) {
        columns[DraftCatalog.TableKey(schema: row.schema, name: row.table), default: []]
            .append(DraftCatalog.SourceColumn(name: row.name, type: row.dataType, isPrimaryKey: row.isPrimaryKey))
    }
    let source: SQLDraftPipeline.DefinitionSource? = definitions.map { all in
        { keys in all.filter { keys.contains($0.key) } }
    }
    let pipeline = SQLDraftPipeline(
        catalog: DraftCatalog(columns: columns, facts: facts), defaultSchema: c.schema, definitions: source)
    var stages: [String] = []
    pipeline.onStage = { stages.append("\($0)") }
    let result = try await pipeline.draft(c.request, adjusting: c.adjust)
    var detail = result.trace
    if !result.fixes.isEmpty { detail.append("fixes: " + result.fixes.joined(separator: " | ")) }
    if !result.problems.isEmpty { detail.append("unresolved: " + result.problems.joined(separator: " | ")) }
    return EvalOutput(sql: result.sql, note: "reads " + result.reads.map(\.description).joined(separator: ", "),
                      detail: detail.joined(separator: "; "))
}
