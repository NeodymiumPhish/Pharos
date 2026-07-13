import AppKit

// MARK: - Schema Tree Node

/// A node in the schema browser outline view.
/// NSOutlineView requires reference-type items, so this is a class.
class SchemaTreeNode: NSObject {

    enum Kind {
        case schema(SchemaInfo)
        case table(TableInfo)
        case view(TableInfo)
        case column(ColumnInfo)
        case partitionGroup(TableInfo)   // "Partitions" folder; associated value = parent table
        case partition(TableInfo)        // a leaf or sub-parent partition
        case loading
    }

    var kind: Kind
    var children: [SchemaTreeNode] = []
    var isLoaded = false
    var hasRowCount = false
    /// Live row count while a CSV import is running into this table. nil when not importing.
    var importingRowCount: Int64?
    weak var parent: SchemaTreeNode?
    /// For a `.partitionGroup`, the current ordering mode of its children.
    var partitionSortMode: PartitionSortMode = .bound
    /// Child partition names known from the filter index (set on `.table`/`.partition`
    /// parents at schema load). Used by the filter to match without loading detail.
    var knownPartitionNames: [String] = []
    /// When a filter is active, the number of this node's partitions matching it.
    var partitionMatchCount: Int = 0

    init(_ kind: Kind, parent: SchemaTreeNode? = nil) {
        self.kind = kind
        self.parent = parent
    }

    func addChild(_ child: SchemaTreeNode) {
        child.parent = self
        children.append(child)
    }

    func removeAllChildren() {
        children.removeAll()
    }

    // MARK: - Display Properties

    var title: String {
        switch kind {
        case .schema(let info): return info.name
        case .table(let info): return info.name
        case .view(let info): return info.name
        case .column(let info): return info.name
        case .partitionGroup: return "Partitions"
        case .partition(let info): return info.name
        case .loading: return "Loading\u{2026}"
        }
    }

    var subtitle: String? {
        switch kind {
        case .table, .view:
            if case .table(let info) = kind, info.isPartitioned {
                var parts: [String] = []
                if let key = PartitionDisplay.keyColumns(fromPartKeyDef: info.partitionKey) {
                    parts.append("by (\(key))")
                }
                if let count = info.partitionCount { parts.append("\(count) partitions") }
                if partitionMatchCount > 0 { parts.append("\(partitionMatchCount) matching") }
                return parts.isEmpty ? " " : parts.joined(separator: " \u{00B7} ")
            }
            // While importing, always show a subtitle (so the import suffix has somewhere to attach).
            if importingRowCount != nil {
                switch kind {
                case .table(let info), .view(let info):
                    if let count = info.rowCountEstimate {
                        return formatCount(count)
                    }
                    return "0 rows"
                default: return ""
                }
            }
            guard hasRowCount else { return " " }
            switch kind {
            case .table(let info), .view(let info):
                if let count = info.rowCountEstimate {
                    return formatCount(count)
                }
                return "0 rows"
            default: return " "
            }
        case .column(let info):
            var parts = [info.dataType]
            if info.isPrimaryKey { parts.append("PK") }
            if !info.isNullable { parts.append("NOT NULL") }
            return parts.joined(separator: ", ")
        case .partitionGroup(let parent):
            if let count = parent.partitionCount { return "\(count) partitions" }
            return "\(children.count) partitions"
        case .partition(let info):
            return PartitionDisplay.boundSummary(info.partitionBound) ?? " "
        default:
            return nil
        }
    }

    /// Uppercase strategy badge (RANGE/LIST/HASH) for a partitioned parent, else nil.
    var partitionBadge: String? {
        if case .table(let info) = kind, info.isPartitioned {
            return info.partitionStrategy?.badgeLabel
        }
        return nil
    }

    /// Localized "Importing: 1,151,448" suffix shown next to the subtitle while a CSV import runs.
    /// nil when no import is active.
    var importingSubtitle: String? {
        guard let count = importingRowCount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "Importing: \(formatted)"
    }

    var icon: NSImage? {
        let name: String
        switch kind {
        case .schema: name = "cylinder.split.1x2"
        case .table(let info): name = info.isPartitioned ? "square.split.2x2" : "tablecells"
        case .view: name = "eye"
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : "textformat"
        case .partitionGroup: name = "rectangle.split.3x1"
        case .partition(let info): name = info.isPartitioned ? "square.split.2x2" : "tablecells.badge.ellipsis"
        case .loading: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }

    var tintColor: NSColor {
        switch kind {
        case .column(let info) where info.isPrimaryKey: return .systemYellow
        case .partition(let info) where PartitionDisplay.boundSummary(info.partitionBound) == "DEFAULT":
            return .tertiaryLabelColor
        case .loading: return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .schema, .table, .view, .partitionGroup: return true
        case .partition: return true  // columns (and sub-partitions if info.isPartitioned)
        default: return false
        }
    }

    // MARK: - Navigation helpers

    /// Walk up the tree to find the schema name.
    var schemaName: String? {
        switch kind {
        case .schema(let info): return info.name
        default: return parent?.schemaName
        }
    }

    /// Walk up to find the table/view name.
    var tableName: String? {
        switch kind {
        case .table(let info), .view(let info): return info.name
        case .partition(let info): return info.name
        case .partitionGroup: return parent?.tableName
        default: return parent?.tableName
        }
    }

    private func formatCount(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM rows", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK rows", Double(count) / 1_000)
        } else {
            return "\(count) rows"
        }
    }
}
