// Adapter for the multi-step pipeline in the working tree. The catalogue is
// built the way the app builds it: the cache's information_schema columns,
// with the facts query's answer for each schema laid over them.
//
// With EVAL_ENDPOINT set (the script's `endpoint` mode) the pipeline asks a
// custom AI endpoint through the app's own client instead of the on-device
// model. The address passes the same rules as in Settings ▸ Intelligence.
import Foundation

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
    IntelligenceBackends.overrideForTesting = EndpointIntelligenceBackend(
        base: base, model: model, contextSize: contextSize, key: { key })
    let place = IntelligenceEndpoint.isOnThisMac(base) ? "on this Mac" : "at \(IntelligenceEndpoint.host(of: base))"
    print("model: \(model) \(place), context \(contextSize) tokens, \(key?.isEmpty == false ? "with" : "without") an API key")
    return true
}()

@MainActor
func evalDraft(_ c: EvalCase, catalog: EvalCatalog) async throws -> EvalOutput {
    _ = endpointIsInstalled
    let factsPath = ProcessInfo.processInfo.environment["EVAL_FACTS"]!
    let facts = try JSONDecoder().decode(
        [String: SchemaDraftFacts].self, from: Data(contentsOf: URL(fileURLWithPath: factsPath)))
    var columns: [DraftCatalog.TableKey: [DraftCatalog.SourceColumn]] = [:]
    for row in catalog.columns.sorted(by: { $0.ordinal < $1.ordinal }) {
        columns[DraftCatalog.TableKey(schema: row.schema, name: row.table), default: []]
            .append(DraftCatalog.SourceColumn(name: row.name, type: row.dataType, isPrimaryKey: row.isPrimaryKey))
    }
    let pipeline = SQLDraftPipeline(catalog: DraftCatalog(columns: columns, facts: facts), defaultSchema: c.schema)
    var stages: [String] = []
    pipeline.onStage = { stages.append("\($0)") }
    let result = try await pipeline.draft(c.request)
    var detail = result.trace
    if !result.fixes.isEmpty { detail.append("fixes: " + result.fixes.joined(separator: " | ")) }
    if !result.problems.isEmpty { detail.append("unresolved: " + result.problems.joined(separator: " | ")) }
    return EvalOutput(sql: result.sql, note: "reads " + result.reads.map(\.description).joined(separator: ", "),
                      detail: detail.joined(separator: "; "))
}
