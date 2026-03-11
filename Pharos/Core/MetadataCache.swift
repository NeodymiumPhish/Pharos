import Foundation
import Combine

/// Caches schema metadata for ALL active connections.
/// Used to feed SQL autocomplete with schema/table/column info.
/// Switching connections restores cached data instantly; only force=true triggers network fetches.
final class MetadataCache: ObservableObject {

    static let shared = MetadataCache()

    @Published private(set) var schemas: [SchemaInfo] = []
    @Published private(set) var tables: [String: [TableInfo]] = [:]
    @Published private(set) var columnsByTable: [String: [ColumnInfo]] = [:]
    @Published private(set) var isLoading = false

    /// Per-connection cached metadata
    private struct ConnectionMetadata {
        var schemas: [SchemaInfo] = []
        var tables: [String: [TableInfo]] = [:]
        var columnsByTable: [String: [ColumnInfo]] = [:]
        var isLoaded: Bool = false
    }

    private var activeConnectionId: String?
    private var connectionCaches: [String: ConnectionMetadata] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var detailTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Load metadata for a connection. Restores from cache if available; fetches from network only when forced or uncached.
    func load(connectionId: String, force: Bool = false) {
        // Cache-hit: restore instantly with no FFI calls
        if !force, let cached = connectionCaches[connectionId], cached.isLoaded {
            activeConnectionId = connectionId
            schemas = cached.schemas
            tables = cached.tables
            columnsByTable = cached.columnsByTable
            isLoading = false
            return
        }

        // Cancel any in-flight tasks for this connection
        loadTasks[connectionId]?.cancel()
        detailTasks[connectionId]?.cancel()

        activeConnectionId = connectionId

        // Clear only this connection's cache entry for fresh fetch
        connectionCaches[connectionId] = ConnectionMetadata()

        // Clear published state and show loading
        schemas = []
        tables = [:]
        columnsByTable = [:]
        isLoading = true

        loadTasks[connectionId] = Task {
            do {
                let fetchedSchemas = try await PharosCore.getSchemas(connectionId: connectionId)
                guard !Task.isCancelled else { return }

                // Publish schema names immediately so the selector is usable
                await MainActor.run {
                    self.schemas = fetchedSchemas
                    self.isLoading = false
                    // Store schemas in cache
                    self.connectionCaches[connectionId]?.schemas = fetchedSchemas
                }

                // Load tables + columns in the background for autocomplete
                await self.loadDetails(connectionId: connectionId, schemas: fetchedSchemas)

                // Mark as fully loaded
                await MainActor.run {
                    self.connectionCaches[connectionId]?.isLoaded = true
                }
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
        guard let connectionId = activeConnectionId else { return }
        // Already have this schema's data loaded
        if tables[schema] != nil { return }

        detailTasks[connectionId]?.cancel()

        detailTasks[connectionId] = Task {
            await self.loadDetails(connectionId: connectionId, schemas: self.schemas, priority: schema)
        }
    }

    /// Clear the active connection's cache and reset published properties (e.g. on disconnect of active).
    func clear() {
        if let activeId = activeConnectionId {
            loadTasks[activeId]?.cancel()
            detailTasks[activeId]?.cancel()
            loadTasks.removeValue(forKey: activeId)
            detailTasks.removeValue(forKey: activeId)
            connectionCaches.removeValue(forKey: activeId)
        }
        activeConnectionId = nil
        schemas = []
        tables = [:]
        columnsByTable = [:]
        isLoading = false
    }

    /// Clear all cached metadata (app-level cleanup).
    func clearAll() {
        for (id, _) in loadTasks { loadTasks[id]?.cancel() }
        for (id, _) in detailTasks { detailTasks[id]?.cancel() }
        loadTasks.removeAll()
        detailTasks.removeAll()
        connectionCaches.removeAll()
        activeConnectionId = nil
        schemas = []
        tables = [:]
        columnsByTable = [:]
        isLoading = false
    }

    /// Clear a specific connection's cache (e.g. when it disconnects).
    /// Preserves other connections' caches.
    func clearConnection(_ id: String) {
        loadTasks[id]?.cancel()
        detailTasks[id]?.cancel()
        loadTasks.removeValue(forKey: id)
        detailTasks.removeValue(forKey: id)
        connectionCaches.removeValue(forKey: id)

        // If this was the active connection, also reset published properties
        if id == activeConnectionId {
            activeConnectionId = nil
            schemas = []
            tables = [:]
            columnsByTable = [:]
            isLoading = false
        }
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
                    // Update cache incrementally
                    self.connectionCaches[connectionId]?.tables = allTables
                    self.connectionCaches[connectionId]?.columnsByTable = allColumns
                }
            } catch {
                NSLog("MetadataCache: Failed to load tables/columns for \(schema.name): \(error)")
            }
        }
    }
}
