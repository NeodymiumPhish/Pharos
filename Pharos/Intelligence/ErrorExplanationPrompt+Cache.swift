import Foundation

/// The one place `ErrorExplanationPrompt` meets the app's metadata cache.
///
/// It is a file of its own so the prompt rules stay compilable — and testable —
/// without `MetadataCache`, `AppKit` or an initialised Rust core behind them.
extension ErrorExplanationPrompt.KnownObjects {

    /// Everything the cache holds for the connection on screen, narrowed to the
    /// tables `sql` names.
    ///
    /// The narrowing happens twice: once here, so a large schema is not copied
    /// into a value that is thrown away a moment later, and once inside
    /// `ErrorExplanationPrompt.describe` — which is the one that counts, and the
    /// one that is tested. Read-only: nothing here asks the cache to load.
    ///
    /// The cache publishes the ACTIVE connection's metadata, so there is no
    /// connection id to pass; a tab on another connection gets `.none` rather
    /// than another connection's tables.
    @MainActor
    static func from(cache: MetadataCache, sql: String) -> ErrorExplanationPrompt.KnownObjects {
        let names = ErrorExplanationPrompt.identifiers(in: sql)
        guard !names.isEmpty else { return .none }

        var tables: [ErrorExplanationPrompt.TableRef] = []
        for (schema, schemaTables) in cache.tables {
            for table in schemaTables where names.contains(table.name.lowercased()) {
                let columns = (cache.columnsByTable["\(schema).\(table.name)"] ?? []).map {
                    ErrorExplanationPrompt.Column(name: $0.name, type: $0.dataType)
                }
                tables.append(
                    ErrorExplanationPrompt.TableRef(
                        schema: schema, table: table.name, columns: columns))
            }
        }
        // A dictionary has no order, and a prompt that changes between two runs
        // of the same failure would give the feedback digest a different hash
        // each time.
        tables.sort { ($0.schema, $0.table) < ($1.schema, $1.table) }
        return ErrorExplanationPrompt.KnownObjects(tables: tables)
    }
}
