// Adapter for the drafter on `main` before the pipeline: one session, two
// tools. The sources are taken from git (`main`), so this keeps grading the
// old design after the working tree has replaced it.
import Foundation

@MainActor
func evalDraft(_ c: EvalCase, catalog: EvalCatalog) async throws -> EvalOutput {
    var schemas: [String: [TableSummary]] = [:]
    let byTable = Dictionary(grouping: catalog.columns) { "\($0.schema).\($0.table)" }
    for key in byTable.keys.sorted() {
        let rows = byTable[key]!.sorted { $0.ordinal < $1.ordinal }
        schemas[rows[0].schema, default: []].append(
            TableSummary(name: rows[0].table, columns: rows.map { (name: $0.name, type: $0.dataType) }))
    }
    let drafter = SQLDrafter(snapshot: SchemaSnapshot(schemas: schemas), defaultSchema: c.schema)
    let draft = try await drafter.draft(c.request)
    return EvalOutput(sql: SQLDraftPolicy.clean(draft.sql), note: draft.note)
}
