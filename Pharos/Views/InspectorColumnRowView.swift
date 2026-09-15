import AppKit

/// One row of the Inspector's Columns section: the column name, its markers
/// ("PK", "NOT NULL"), and its type in a monospaced trailing column so the
/// types line up down the list.
///
/// Lives outside `InspectorViewController` so `scripts/test-inspector-column-row.sh`
/// can compile it: `InspectorViewController` pulls in the whole PharosCore FFI
/// bridge, which cannot link in a plain swiftc binary.
final class ColumnRowView: NSView {

    let schema: String
    let table: String
    let columnName: String

    let nameLabel = NSTextField(labelWithString: "")
    let markerLabel = NSTextField(labelWithString: "")
    let typeLabel = NSTextField(labelWithString: "")

    /// The type never gives up more than this, however long the name is: a
    /// truncated `timestamp with ti…` still says more than no type at all.
    static let minimumTypeWidth: CGFloat = 60

    init(schema: String, table: String, column: ColumnInfo) {
        self.schema = schema
        self.table = table
        self.columnName = column.name
        super.init(frame: .zero)

        // A column name is server-supplied data, like every other identifier
        // this pane draws.
        nameLabel.stringValue = DisplayEscape.escaped(column.name)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        // The name yields first: it is the one part the reader can still
        // recognise from its head, and the type column must survive.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var markers: [String] = []
        if column.isPrimaryKey { markers.append("PK") }
        if !column.isNullable { markers.append("NOT NULL") }
        markerLabel.stringValue = markers.joined(separator: " \u{00B7} ")
        markerLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        markerLabel.textColor = column.isPrimaryKey ? .systemYellow : .tertiaryLabelColor
        markerLabel.isHidden = markers.isEmpty
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        markerLabel.setContentHuggingPriority(.required, for: .horizontal)

        typeLabel.stringValue = DisplayEscape.escaped(column.dataType)
        typeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.alignment = .right
        typeLabel.lineBreakMode = .byTruncatingTail
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        typeLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(nameLabel)
        addSubview(markerLabel)
        addSubview(typeLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            markerLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            markerLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            typeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: markerLabel.trailingAnchor, constant: 8),
            typeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            typeLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            typeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTypeWidth),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            ([nameLabel.stringValue, typeLabel.stringValue] + markers).joined(separator: ", ")
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// `schema.table.column`, each part quoted the way the rest of the app
    /// quotes identifiers — the form that pastes straight into a query.
    var qualifiedName: String {
        quotedQualifiedName(schema: schema, table: table) + "." + quotedSqlIdentifier(columnName)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyName = NSMenuItem(title: "Copy Name", action: #selector(copyName), keyEquivalent: "")
        copyName.target = self
        menu.addItem(copyName)
        let copyQualified = NSMenuItem(
            title: "Copy Qualified Name", action: #selector(copyQualifiedName), keyEquivalent: "")
        copyQualified.target = self
        menu.addItem(copyQualified)
        return menu
    }

    /// The RAW name, not the escaped display string: an analyst pastes this
    /// into a query, and `<U+202E>` is not an identifier.
    @objc func copyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(columnName, forType: .string)
    }

    @objc func copyQualifiedName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qualifiedName, forType: .string)
    }
}
