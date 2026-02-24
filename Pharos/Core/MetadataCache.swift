import Foundation
import Combine

/// Caches schema metadata for the active connection.
/// Used to feed SQL autocomplete with schema/table/column info.
final class MetadataCache: ObservableObject {

    static let shared = MetadataCache()

    @Published private(set) var schemas: [SchemaInfo] = []
    @Published private(set) var tables: [String: [TableInfo]] = [:]
    @Published private(set) var columnsByTable: [String: [ColumnInfo]] = [:]

    private var loadedConnectionId: String?
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Load metadata for a connection. Cancels any in-progress load.
    func load(connectionId: String) {
        guard connectionId != loadedConnectionId else { return }
        loadTask?.cancel()
        loadedConnectionId = connectionId

        loadTask = Task {
            do {
                let fetchedSchemas = try await PharosCore.getSchemas(connectionId: connectionId)
                guard !Task.isCancelled else { return }

                var allTables: [String: [TableInfo]] = [:]
                var allColumns: [String: [ColumnInfo]] = [:]

                for schema in fetchedSchemas {
                    guard !Task.isCancelled else { return }

                    let schemaTables = try await PharosCore.getTables(
                        connectionId: connectionId, schema: schema.name)
                    let schemaColumns = try await PharosCore.getSchemaColumns(
                        connectionId: connectionId, schema: schema.name)

                    allTables[schema.name] = schemaTables

                    // Group SchemaColumnInfo by tableName
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
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.schemas = fetchedSchemas
                    self.tables = allTables
                    self.columnsByTable = allColumns
                }
            } catch {
                NSLog("MetadataCache: Failed to load metadata: \(error)")
            }
        }
    }

    /// Clear cached metadata (e.g. on disconnect).
    func clear() {
        loadTask?.cancel()
        loadedConnectionId = nil
        schemas = []
        tables = [:]
        columnsByTable = [:]
    }
}
