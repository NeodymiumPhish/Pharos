// The catalogue as the app's MetadataCache holds it: one row per column, from
// the same information_schema query `get_schema_columns` runs
// (pharos-core/src/db/postgres.rs). Written by eval-sql-draft.sh.
import Foundation

struct EvalColumnRow: Decodable {
    let schema: String
    let table: String
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let ordinal: Int
}

struct EvalCatalog: Decodable {
    let columns: [EvalColumnRow]
}
