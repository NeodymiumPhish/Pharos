// Adapter for the multi-step pipeline in the working tree. The catalogue is
// built the way the app builds it: the cache's information_schema columns,
// with the facts query's answer for each schema laid over them.
import Foundation

@MainActor
func evalDraft(_ c: EvalCase, catalog: EvalCatalog) async throws -> EvalOutput {
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
