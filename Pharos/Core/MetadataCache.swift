import Foundation
import Combine

/// Caches schema metadata for the active connection.
/// Used to feed SQL autocomplete with schema/table/column info.
final class MetadataCache: ObservableObject {

    static let shared = MetadataCache()

    @Published private(set) var schemas: [SchemaInfo] = []
    @Published private(set) var tables: [String: [TableInfo]] = [:]
    @Published private(set) var columnsByTable: [String: [ColumnInfo]] = [:]
    @Published private(set) var isLoading = false

    private var loadedConnectionId: String?
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var prioritySchema: String?

    private init() {}

    /// Load metadata for a connection. Cancels any in-progress load.
    func load(connectionId: String) {
        guard connectionId != loadedConnectionId else { return }
        loadTask?.cancel()
        detailTask?.cancel()
        loadedConnectionId = connectionId
        prioritySchema = nil

        // Clear stale data immediately and show loading state
        schemas = []
        tables = [:]
        columnsByTable = [:]
        isLoading = true

        loadTask = Task {
            do {
                let fetchedSchemas = try await PharosCore.getSchemas(connectionId: connectionId)
                guard !Task.isCancelled else { return }

                // Publish schema names immediately so the selector is usable
                await MainActor.run {
                    self.schemas = fetchedSchemas
                    self.isLoading = false
                }

                // Load tables + columns in the background for autocomplete
                await self.loadDetails(connectionId: connectionId, schemas: fetchedSchemas)
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
                NSLog("MetadataCache: Failed to load metadata: \(error)")
            }
        }
    }

    /// Prioritize loading a specific schema's tables/columns first.
    /// Cancels the current detail load and restarts with the priority schema.
    func prioritize(schema: String) {
        guard let connectionId = loadedConnectionId else { return }
        // Already have this schema's data loaded
        if tables[schema] != nil { return }

        prioritySchema = schema
        detailTask?.cancel()

        detailTask = Task {
            await self.loadDetails(connectionId: connectionId, schemas: self.schemas, priority: schema)
        }
    }

    /// Clear cached metadata (e.g. on disconnect).
    func clear() {
        loadTask?.cancel()
        detailTask?.cancel()
        loadedConnectionId = nil
        prioritySchema = nil
        schemas = []
        tables = [:]
        columnsByTable = [:]
        isLoading = false
    }

    // MARK: - Private

    /// Load tables + columns for schemas, optionally prioritizing one schema first.
    private func loadDetails(connectionId: String, schemas: [SchemaInfo], priority: String? = nil) async {
        // Determine load order: priority schema first, then remaining
        let ordered: [SchemaInfo]
        if let priority {
            let first = schemas.filter { $0.name == priority }
            let rest = schemas.filter { $0.name != priority }
            ordered = first + rest
        } else {
            ordered = schemas
        }

        // Preserve already-loaded data (from a previous partial load)
        var allTables = await MainActor.run { self.tables }
        var allColumns = await MainActor.run { self.columnsByTable }

        for schema in ordered {
            guard !Task.isCancelled else { return }
            // Skip schemas we already loaded
            if allTables[schema.name] != nil { continue }

            do {
                let schemaTables = try await PharosCore.getTables(
                    connectionId: connectionId, schema: schema.name)
                let schemaColumns = try await PharosCore.getSchemaColumns(
                    connectionId: connectionId, schema: schema.name)

                guard !Task.isCancelled else { return }

                allTables[schema.name] = schemaTables

                var byTable: [String: [ColumnInfo]] = [:]
                for col in schemaColumns {
                    let info = ColumnInfo(
                        name: col.name,
                        dataType: col.dataType,
                        isNullable: col.isNullable,
                        isPrimaryKey: col.isPrimaryKey,
                        ordinalPosition: col.ordinalPosition,
                        columnDefault: col.columnDefault
                    )
                    byTable[col.tableName, default: []].append(info)
                }
                for (tableName, cols) in byTable {
                    allColumns["\(schema.name).\(tableName)"] = cols
                }

                // Publish incrementally so autocomplete updates as each schema loads
                await MainActor.run {
                    self.tables = allTables
                    self.columnsByTable = allColumns
                }
            } catch {
                NSLog("MetadataCache: Failed to load tables/columns for \(schema.name): \(error)")
            }
        }
    }
}
