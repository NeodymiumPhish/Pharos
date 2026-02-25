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
        case loading
    }

    var kind: Kind
    var children: [SchemaTreeNode] = []
    var isLoaded = false
    var hasRowCount = false
    weak var parent: SchemaTreeNode?

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
        case .loading: return "Loading\u{2026}"
        }
    }

    var subtitle: String? {
        switch kind {
        case .table, .view:
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
        default:
            return nil
        }
    }

    var icon: NSImage? {
        let name: String
        switch kind {
        case .schema: name = "cylinder.split.1x2"
        case .table: name = "tablecells"
        case .view: name = "eye"
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : "textformat"
        case .loading: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }

    var tintColor: NSColor {
        switch kind {
        case .column(let info) where info.isPrimaryKey: return .systemYellow
        case .loading: return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .schema, .table, .view: return true
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
