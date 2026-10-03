import Foundation
import Combine
import os

/// Where the cache gets metadata from. The app reads it through the Rust core
/// (`MetadataCache+Shared.swift`); a test passes its own.
struct MetadataLoader {
    var schemas: (_ connectionId: String) async throws -> [SchemaInfo]
    var tables: (_ connectionId: String, _ schema: String) async throws -> [TableInfo]
    var columns: (_ connectionId: String, _ schema: String) async throws -> [SchemaColumnInfo]
}

/// Schema metadata for every open connection, one entry per connection id.
/// Used to feed SQL autocomplete, the schema pop-up and the inspector.
///
/// Every tab is its own window and can use its own connection, so nothing here
/// is "the active connection": each consumer asks for its own connection's
/// entry (`metadata(for:)`, `publisher(for:)`). A load of one connection never
/// clears or republishes another. Only `force` (or an expired entry) fetches
/// again; otherwise a load of a loaded connection does nothing.
@MainActor
final class MetadataCache: ObservableObject {

    /// One connection's metadata, as consumers see it.
    struct ConnectionMetadata: Equatable {
        var schemas: [SchemaInfo] = []
        var tables: [String: [TableInfo]] = [:]
        /// Keyed `"schema.table"`.
        var columnsByTable: [String: [ColumnInfo]] = [:]
        var isLoading = false
        /// Bumped by every change, so equality — what `removeDuplicates` runs
        /// on every publish — compares two numbers instead of whole catalogs.
        fileprivate(set) var revision = 0

        static let empty = ConnectionMetadata()

        static func == (a: ConnectionMetadata, b: ConnectionMetadata) -> Bool {
            a.revision == b.revision && a.isLoading == b.isLoading
        }
    }

    @Published private(set) var entries: [String: ConnectionMetadata] = [:]

    private let loader: MetadataLoader
    /// `metadataCacheTtlMinutes`: 0 means never expire — an entry lives until
    /// its connection closes or the user refreshes by hand.
    private let ttlMinutes: () -> Int
    /// When each connection's full load finished; absent while it is filling.
    private var loadedAt: [String: Date] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var detailTasks: [String: Task<Void, Never>] = [:]

    init(loader: MetadataLoader, ttlMinutes: @escaping () -> Int) {
        self.loader = loader
        self.ttlMinutes = ttlMinutes
    }

    // MARK: - Reading

    func metadata(for connectionId: String?) -> ConnectionMetadata {
        connectionId.flatMap { entries[$0] } ?? .empty
    }

    /// `connectionId`'s entry now and on every change to it — and only to it.
    func publisher(for connectionId: String?) -> AnyPublisher<ConnectionMetadata, Never> {
        $entries
            .map { entries in connectionId.flatMap { entries[$0] } ?? .empty }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Loading

    /// Load `connectionId`'s metadata, unless it is already loaded and fresh.
    func load(connectionId: String, force: Bool = false) {
        if !force, isFresh(connectionId) { return }
        loadTasks[connectionId]?.cancel()
        detailTasks[connectionId]?.cancel()
        loadedAt[connectionId] = nil
        update(connectionId) { $0 = ConnectionMetadata(isLoading: true) }

        loadTasks[connectionId] = Task {
            do {
                let schemas = try await loader.schemas(connectionId)
                guard !Task.isCancelled else { return }
                // Schema names first, so the schema pop-up is usable at once.
                update(connectionId) {
                    $0.schemas = schemas
                    $0.isLoading = false
                }
                await loadDetails(connectionId: connectionId, schemas: schemas)
                guard !Task.isCancelled else { return }
                loadedAt[connectionId] = Date()
            } catch {
                update(connectionId) { $0.isLoading = false }
                Log.schema.error("MetadataCache: Failed to load metadata: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Load `schema`'s tables and columns for `connectionId` before the rest,
    /// so the schema the user works in completes first.
    func prioritize(schema: String, connectionId: String) {
        guard let entry = entries[connectionId], entry.tables[schema] == nil else { return }
        detailTasks[connectionId]?.cancel()
        detailTasks[connectionId] = Task {
            await loadDetails(connectionId: connectionId, schemas: entry.schemas, priority: schema)
        }
    }

    // MARK: - Clearing

    /// Forget one connection's metadata (it disconnected, failed or was
    /// deleted). Other connections keep theirs.
    func clearConnection(_ id: String) {
        loadTasks.removeValue(forKey: id)?.cancel()
        detailTasks.removeValue(forKey: id)?.cancel()
        loadedAt[id] = nil
        entries[id] = nil
    }

    /// Forget everything. Returns the connections it held, so the caller can
    /// load the ones still open again — otherwise their windows would stay
    /// empty until something else asked.
    @discardableResult
    func clearAll() -> [String] {
        let held = Array(entries.keys)
        for task in loadTasks.values { task.cancel() }
        for task in detailTasks.values { task.cancel() }
        loadTasks.removeAll()
        detailTasks.removeAll()
        loadedAt.removeAll()
        entries.removeAll()
        return held
    }

    // MARK: - Private

    private func isFresh(_ id: String) -> Bool {
        guard let finished = loadedAt[id] else { return false }
        let minutes = ttlMinutes()
        return minutes <= 0 || Date().timeIntervalSince(finished) <= TimeInterval(minutes) * 60
    }

    private func update(_ id: String, _ change: (inout ConnectionMetadata) -> Void) {
        var entry = entries[id] ?? ConnectionMetadata()
        change(&entry)
        entry.revision += 1
        entries[id] = entry
    }

    /// Load tables and columns for `schemas`, the priority schema first.
    private func loadDetails(connectionId: String, schemas: [SchemaInfo], priority: String? = nil) async {
        let ordered: [SchemaInfo]
        if let priority {
            ordered = schemas.filter { $0.name == priority } + schemas.filter { $0.name != priority }
        } else {
            ordered = schemas
        }

        // Start from what is already loaded (a previous, partial load).
        var allTables = entries[connectionId]?.tables ?? [:]
        var allColumns = entries[connectionId]?.columnsByTable ?? [:]

        // Publish after the priority schema and once at the end, not after
        // every schema: each publish reaches every window's subscribers, and
        // an N-schema load must not cost N full propagations.
        for schema in ordered {
            guard !Task.isCancelled else { return }
            if allTables[schema.name] != nil { continue }
            do {
                let schemaTables = try await loader.tables(connectionId, schema.name)
                let schemaColumns = try await loader.columns(connectionId, schema.name)
                guard !Task.isCancelled else { return }

                allTables[schema.name] = schemaTables
                var byTable: [String: [ColumnInfo]] = [:]
                for col in schemaColumns {
                    byTable[col.tableName, default: []].append(ColumnInfo(
                        name: col.name, dataType: col.dataType, isNullable: col.isNullable,
                        isPrimaryKey: col.isPrimaryKey, ordinalPosition: col.ordinalPosition,
                        columnDefault: col.columnDefault))
                }
                for (tableName, cols) in byTable {
                    allColumns["\(schema.name).\(tableName)"] = cols
                }
                if let priority, schema.name == priority {
                    let (t, c) = (allTables, allColumns)
                    update(connectionId) {
                        $0.tables = t
                        $0.columnsByTable = c
                    }
                }
            } catch {
                Log.schema.error("MetadataCache: Failed to load tables/columns for \(schema.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        guard !Task.isCancelled, entries[connectionId] != nil else { return }
        let (t, c) = (allTables, allColumns)
        update(connectionId) {
            $0.tables = t
            $0.columnsByTable = c
        }
    }
}
