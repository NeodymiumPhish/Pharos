import Foundation

extension MetadataLoader {
    /// The app's loader: the Rust core's catalog queries.
    static let pharosCore = MetadataLoader(
        schemas: { try await PharosCore.getSchemas(connectionId: $0) },
        tables: { try await PharosCore.getTables(connectionId: $0, schema: $1) },
        columns: { try await PharosCore.getSchemaColumns(connectionId: $0, schema: $1) })
}

extension MetadataCache {
    static let shared = MetadataCache(
        loader: .pharosCore,
        ttlMinutes: { Int(AppStateManager.shared.settings.diagnostics.metadataCacheTtlMinutes) })

    /// Settings ▸ Advanced ▸ Clear Metadata Cache: forget everything, then load
    /// again every connection that is still open, so no window is left with an
    /// empty schema pop-up and no completions.
    func clearAllAndReloadOpenConnections() {
        for id in clearAll() where AppStateManager.shared.status(for: id) == .connected {
            load(connectionId: id)
        }
    }
}
