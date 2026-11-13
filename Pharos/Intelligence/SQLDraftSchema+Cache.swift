import Foundation

/// The one adapter from `MetadataCache` to `DraftCatalog`, kept apart so the
/// catalogue and the pipeline compile without the cache in
/// `scripts/test-sql-draft-pipeline.sh` and `scripts/eval-sql-draft.sh`.
extension DraftCatalog {

    /// Everything the schema cache holds for one connection — the tab's
    /// own — with the facts fetched for some of its schemas laid over it.
    ///
    /// Columns arrive keyed `"schema.table"`; a table whose columns have not
    /// been fetched yet contributes its name with no columns, so it can still
    /// be ranked and named.
    static func from(_ cache: MetadataCache.ConnectionMetadata, facts: [String: SchemaDraftFacts]) -> DraftCatalog {
        var columns: [TableKey: [SourceColumn]] = [:]
        var partitions: Set<TableKey> = []
        for schema in cache.schemas {
            for table in cache.tables[schema.name] ?? [] {
                if table.isPartition { partitions.insert(TableKey(schema: schema.name, name: table.name)) }
                let source = cache.columnsByTable["\(schema.name).\(table.name)"] ?? []
                columns[TableKey(schema: schema.name, name: table.name)] = source
                    .sorted { $0.ordinalPosition < $1.ordinalPosition }
                    .map { SourceColumn(name: $0.name, type: $0.dataType, isPrimaryKey: $0.isPrimaryKey) }
            }
        }
        var catalog = DraftCatalog(columns: columns, facts: facts)
        catalog.partitions = partitions
        return catalog
    }
}
