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
        case .schema(let info): return DisplayEscape.escaped(info.name)
        case .table(let info): return DisplayEscape.escaped(info.name)
        case .view(let info): return DisplayEscape.escaped(info.name)
        case .column(let info): return DisplayEscape.escaped(info.name)
        case .partitionGroup: return "Partitions"
        case .partition(let info): return DisplayEscape.escaped(info.name)
        case .loading: return "Loading\u{2026}"
        }
    }

    var subtitle: String? {
        switch kind {
        case .table, .view:
            if case .table(let info) = kind, info.isPartitioned {
                var parts: [String] = []
                if let key = PartitionDisplay.keyColumns(fromPartKeyDef: info.partitionKey) {
                    parts.append("by (\(DisplayEscape.escaped(key)))")
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
            // The bare " " sentinel means "reserve the subtitle line, draw nothing".
            // It must NOT be escaped: DisplayEscape.escaped(" ") is "<U+0020>",
            // which would put a pill in every rowless table's row.
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
            var parts = [DisplayEscape.escaped(info.dataType)]
            if info.isPrimaryKey { parts.append("PK") }
            if !info.isNullable { parts.append("NOT NULL") }
            return parts.joined(separator: ", ")
        case .partitionGroup(let parent):
            if let count = parent.partitionCount { return "\(count) partitions" }
            return "\(children.count) partitions"
        case .partition(let info):
            return PartitionDisplay.boundSummary(info.partitionBound)
                .map(DisplayEscape.escaped) ?? " "
        default:
            return nil
        }
    }

    /// What the one-line row cannot spell out: the exact row count and the size
    /// on disk, both locale-aware. The row's caption is the abbreviated form
    /// ("1.2M rows") because that is all that fits beside the name; this is the
    /// figure an analyst sizing up a table actually needs, and the Inspector
    /// carries it too. Nil when neither number is known.
    var tooltip: String? {
        let info: TableInfo
        switch kind {
        case .table(let i), .view(let i), .partition(let i): info = i
        default: return nil
        }
        var parts: [String] = []
        if let rows = info.rowCountEstimate {
            let formatted = Self.decimalFormatter.string(from: NSNumber(value: rows)) ?? "\(rows)"
            parts.append("\(formatted) rows")
        }
        if let bytes = info.totalSizeBytes {
            parts.append(Self.byteCountFormatter.string(fromByteCount: bytes))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Shared formatters — a tooltip is built per visible row on every reload,
    /// and both of these are expensive to construct.
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .autoupdatingCurrent
        return f
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Uppercase badge for a parent: the strategy (RANGE/LIST/HASH) for a
    /// declarative one, INHERITS for a legacy inheritance tree — which has no
    /// strategy to read, so without this it would carry no badge at all and
    /// the two mechanisms would look the same.
    var partitionBadge: String? {
        if case .table(let info) = kind, info.isPartitioned {
            if info.partitionMechanism == .inheritance {
                return PartitionMechanism.inheritance.badgeLabel
            }
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
            name = info.isPrimaryKey ? "key.fill" : ColumnTypeIcon.symbolName(forDataType: info.dataType)
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
        case .partition(let info): return info.schemaName
        case .partitionGroup(let parent): return parent.schemaName
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
