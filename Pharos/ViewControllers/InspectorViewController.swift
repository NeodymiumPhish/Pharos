import AppKit

/// Inspector view controller for the right pane.
/// Shows single-row detail when one row is selected, placeholder otherwise.
class InspectorViewController: NSViewController {

    private let noSelectionLabel = NSTextField(labelWithString: "No Selection")
    private var scrollView = NSScrollView()
    private var stackView = NSStackView()
    private var currentRowNumber: Int?
    private var currentDataRow: Int?
    private var currentTagEntries: [TagInspectorEntry] = []

    /// True only while row detail is on screen. This pane is SHARED — the
    /// schema browser and the SQL view write to it too — so anything that
    /// wants to refresh row detail in place must ask this first, or it
    /// silently replaces whatever else the analyst was reading.
    var isShowingRowDetail: Bool { currentRowNumber != nil }

    /// Per-tag controls, wired by ContentViewController. Buttons only render
    /// when the closure is set.
    var onEditTag: ((String) -> Void)?
    var onDeleteTag: ((String) -> Void)?

    override func loadView() {
        let container = NSView()

        // No-selection placeholder label
        noSelectionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noSelectionLabel.textColor = .secondaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view with flipped document view
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(stackView)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true

        container.addSubview(scrollView)
        container.addSubview(noSelectionLabel)

        NSLayoutConstraint.activate([
            noSelectionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            noSelectionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            // Pin bottom to stack view bottom + padding so scroll content size is correct
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: stackView.bottomAnchor, constant: 12),
        ])

        view = container
    }

    // MARK: - Public API

    /// Forgets the row-detail identity. Every entry point that puts something
    /// OTHER than row detail on screen calls it, so `isShowingRowDetail` reads
    /// false and the next `showRowDetail` cannot dedup against a view that is
    /// no longer there.
    private func clearRowDetailIdentity() {
        currentRowNumber = nil
        currentDataRow = nil
        currentTagEntries = []
    }

    func showNoSelection() {
        clearRowDetailIdentity()
        scrollView.isHidden = true
        noSelectionLabel.stringValue = "No Selection"
        noSelectionLabel.isHidden = false
    }

    func showRowDetail(
        columns: [ColumnDef],
        row: [AnyCodable],
        rowNumber: Int,
        dataRow: Int,
        totalRows: Int,
        columnCategories: [PGTypeCategory],
        tagEntries: [TagInspectorEntry] = []
    ) {
        // Skip the rebuild only when the whole identity is unchanged.
        // `rowNumber` is a DISPLAY position, and a sort or a filter change
        // hands the same position to a different record, so `dataRow` — the
        // record itself — joins it; without that, two untagged rows compare
        // equal and the pane keeps the previous row's values. `tagEntries`
        // joins it too, because a tag edit must repaint this section while
        // the selection stays put, which a row-only guard swallowed.
        if currentRowNumber == rowNumber && currentDataRow == dataRow
            && currentTagEntries == tagEntries { return }
        currentRowNumber = rowNumber
        currentDataRow = dataRow
        currentTagEntries = tagEntries

        noSelectionLabel.isHidden = true
        scrollView.isHidden = false

        // Clear previous content
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Header: "Row Detail" + "N of M"
        let titleLabel = NSTextField(labelWithString: "Row Detail")
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let countLabel = NSTextField(labelWithString: "\(rowNumber) of \(totalRows)")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, countLabel])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        stackView.addArrangedSubview(headerStack)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        stackView.addArrangedSubview(separator)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Tags section — above the columns; the finding comes before the data.
        addTagSection(tagEntries)

        // Column key-value pairs
        for (index, colDef) in columns.enumerated() {
            let category = index < columnCategories.count ? columnCategories[index] : .string
            let keyLabel = makeKeyLabel(name: colDef.name, dataType: colDef.dataType)
            let value: AnyCodable? = index < row.count ? row[index] : nil
            let valueLabel = makeValueLabel(value: value, category: category)

            stackView.addArrangedSubview(keyLabel)
            stackView.addArrangedSubview(valueLabel)
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            // Add spacer between column groups
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
            stackView.addArrangedSubview(spacer)
        }
    }

    /// Shows detail for a partitioned parent table (`TableInfo.isPartitioned`).
    /// Also used for a selected `.partitionGroup` node — it shares the same
    /// parent `TableInfo`, so its detail is identical.
    func showPartitionedTableDetail(_ info: TableInfo) {
        beginDetailSection(title: "Partitioned Table", subtitle: info.name)

        addDetailField("Strategy", info.partitionStrategy?.badgeLabel ?? "\u{2014}")
        addDetailField("Partition key", PartitionDisplay.keyColumns(fromPartKeyDef: info.partitionKey) ?? "\u{2014}")
        addDetailField("Partitions", info.partitionCount.map(String.init) ?? "\u{2014}")
        addDetailField("Rows", formatRowCount(info.rowCountEstimate))
        addDetailField("Size", formatByteSize(info.totalSizeBytes))
    }

    /// Shows detail for a selected partition (`TableInfo.isPartition`).
    /// `parentName` is the enclosing partitioned table's name, when known.
    func showPartitionDetail(_ info: TableInfo, parentName: String?) {
        beginDetailSection(title: "Partition", subtitle: info.name)

        addDetailField("Parent", parentName ?? "\u{2014}")
        let bound = PartitionDisplay.boundSummary(info.partitionBound)
        addDetailField("Bound", bound ?? "\u{2014}")
        if bound == "DEFAULT" {
            addDetailNote("DEFAULT partition")
        }
        addDetailField("Rows", formatRowCount(info.rowCountEstimate))
        addDetailField("Size", formatByteSize(info.totalSizeBytes))
        if info.isPartitioned {
            addDetailNote("Sub-partitioned by \(info.partitionStrategy?.badgeLabel ?? "?")")
        }
    }

    /// Shows detail for a regular (non-partitioned) table, view, or foreign table.
    func showTableDetail(_ info: TableInfo) {
        let category: String
        switch info.tableType {
        case .view: category = "View"
        case .foreignTable: category = "Foreign Table"
        case .partitionedTable: category = "Partitioned Table"
        case .table: category = "Table"
        }
        beginDetailSection(title: category, subtitle: info.name)

        addDetailField("Schema", info.schemaName)
        addDetailField("Rows", formatRowCount(info.rowCountEstimate))
        if info.totalSizeBytes != nil {
            addDetailField("Size", formatByteSize(info.totalSizeBytes))
        }
    }

    /// Shows detail for a selected column. `parentName` is the enclosing
    /// table/partition name, when known.
    func showColumnDetail(_ info: ColumnInfo, parentName: String?) {
        beginDetailSection(title: "Column", subtitle: info.name)

        if let parentName {
            addDetailField("Table", parentName)
        }
        addDetailField("Type", info.dataType)
        addDetailField("Nullable", info.isNullable ? "Yes" : "No")
        addDetailField("Primary key", info.isPrimaryKey ? "Yes" : "No")
        if let columnDefault = info.columnDefault, !columnDefault.isEmpty {
            addDetailField("Default", columnDefault)
        }
    }

    /// Shows a query's raw SQL text as wrapped, monospaced, selectable body
    /// text with the same syntax coloring as the query editor — used when a
    /// workspace-history preview row is selected.
    func showSQL(_ sql: String, title: String = "Query") {
        beginDetailSection(title: title, subtitle: "")

        let label = makeFieldValueLabel(sql, color: .labelColor)
        label.attributedStringValue = SQLSyntaxHighlighter.attributedString(
            for: sql,
            font: label.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            baseColor: .labelColor
        )
        // attributedStringValue resets wrapping/line count, so re-apply after.
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true
        stackView.addArrangedSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func showAggregation(
        columns: [ColumnDef],
        rows: [[AnyCodable]],
        selectionCount: Int,
        columnCategories: [PGTypeCategory]
    ) {
        clearRowDetailIdentity()
        noSelectionLabel.isHidden = true
        scrollView.isHidden = false

        // Clear previous content
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Compute aggregations
        let aggregations = computeAggregations(columns: columns, rows: rows, categories: columnCategories)

        // Header: "Selection Summary" + "N rows"
        let titleLabel = NSTextField(labelWithString: "Selection Summary")
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let countLabel = NSTextField(labelWithString: "\(selectionCount) rows")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, countLabel])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        stackView.addArrangedSubview(headerStack)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        stackView.addArrangedSubview(separator)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Summary line
        let summaryLabel = NSTextField(labelWithString: "Count: \(selectionCount)  Columns: \(columns.count)")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .labelColor
        stackView.addArrangedSubview(summaryLabel)

        // Second separator
        let separator2 = NSBox()
        separator2.boxType = .separator
        stackView.addArrangedSubview(separator2)
        separator2.translatesAutoresizingMaskIntoConstraints = false
        separator2.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Per-column sections
        for agg in aggregations {
            // Column header
            let colHeader = makeKeyLabel(name: agg.columnName, dataType: agg.dataType)
            stackView.addArrangedSubview(colHeader)

            // Count / Distinct / NULL — each on its own line. When the selection
            // has exactly one distinct value, the count keeps its place and the
            // value follows in parentheses, so a lone "443" can't be misread as
            // a count of 443 distinct values.
            let nullCount = agg.totalCount - agg.nonNullCount
            var statLines = ["Count: \(agg.nonNullCount)"]
            if agg.distinctCount == 1, let only = agg.distinctValues.first {
                statLines.append("Distinct: 1 (\(only))")
            } else {
                statLines.append("Distinct: \(agg.distinctCount)")
            }
            if nullCount > 0 { statLines.append("NULL: \(nullCount)") }
            for line in statLines {
                let statLabel = NSTextField(labelWithString: line)
                statLabel.font = .systemFont(ofSize: 11)
                statLabel.textColor = .labelColor
                statLabel.lineBreakMode = .byTruncatingTail
                statLabel.toolTip = line
                stackView.addArrangedSubview(statLabel)
                statLabel.translatesAutoresizingMaskIntoConstraints = false
                statLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }

            // Type-specific stats
            switch agg.category {
            case .numeric:
                if let numMin = agg.numericMin, let numMax = agg.numericMax {
                    let minMaxLine = makeStatLine(pairs: [
                        ("Min: ", formatAggregate(numMin), .systemBlue),
                        ("  Max: ", formatAggregate(numMax), .systemBlue),
                    ])
                    stackView.addArrangedSubview(minMaxLine)

                    let sumAvgLine = makeStatLine(pairs: [
                        ("Sum: ", formatAggregate(agg.numericSum), .systemBlue),
                        ("  Avg: ", formatAggregate(agg.numericAvg ?? 0), .systemBlue),
                    ])
                    stackView.addArrangedSubview(sumAvgLine)
                }

            case .temporal:
                if let earliest = agg.earliest {
                    let earliestLine = makeStatLine(pairs: [
                        ("Earliest: ", earliest, .systemPurple),
                    ])
                    stackView.addArrangedSubview(earliestLine)
                }
                if let latest = agg.latest {
                    let latestLine = makeStatLine(pairs: [
                        ("Latest: ", latest, .systemPurple),
                    ])
                    stackView.addArrangedSubview(latestLine)
                }

            case .boolean:
                let boolLine = makeStatLine(pairs: [
                    ("True: ", "\(agg.trueCount)", .systemGreen),
                    ("  False: ", "\(agg.falseCount)", .systemRed),
                ])
                stackView.addArrangedSubview(boolLine)

            default:
                break
            }

            // Spacer between column sections
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
            stackView.addArrangedSubview(spacer)
        }
    }

    // MARK: - Partition Detail Helpers

    /// Clears the stack and installs a "Title" + right-aligned subtitle header
    /// followed by a separator — the same header/separator shape used by
    /// `showRowDetail`/`showAggregation` (title on the left, an identifying
    /// value on the right).
    private func beginDetailSection(title: String, subtitle: String) {
        clearRowDetailIdentity()
        noSelectionLabel.isHidden = true
        scrollView.isHidden = false

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .right
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        stackView.addArrangedSubview(headerStack)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        stackView.addArrangedSubview(separator)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// Adds a label -> value row, mirroring the column key/value rows in
    /// `showRowDetail` (secondary-label key above a monospaced value, with a
    /// spacer between rows).
    private func addDetailField(_ name: String, _ value: String, color: NSColor = .labelColor) {
        let keyLabel = makeFieldLabel(name)
        let valueLabel = makeFieldValueLabel(value, color: color)

        stackView.addArrangedSubview(keyLabel)
        stackView.addArrangedSubview(valueLabel)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stackView.addArrangedSubview(spacer)
    }

    /// Adds a standalone callout line (e.g. "DEFAULT partition").
    private func addDetailNote(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemOrange
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        stackView.addArrangedSubview(label)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stackView.addArrangedSubview(spacer)
    }

    // MARK: - Tags Section

    /// The Tags section: one block per matching tag — swatch + name + state,
    /// the note, the displayed tuple's values with match marks, the
    /// cross-tuple explanation, and the per-tag controls — then a separator
    /// to hand back to the column list. Renders nothing for an untagged row.
    private func addTagSection(_ entries: [TagInspectorEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            addTagHeader(entry)
            if let note = entry.note { addTagNote(note) }
            // A solid entry can still show a dash: when the recorded tuple was
            // deleted, `TagInspectorModel` falls through to the closest
            // remaining one rather than let the entry vanish under the bar.
            for value in entry.values { addTagValueRow(value) }
            if entry.isCrossTuple {
                addDetailNote("Partial: matched values come from different tagged rows.")
            }
            addTagButtons(tagId: entry.tagId)
            addTagSpacer()
        }

        let divider = NSBox()
        divider.boxType = .separator
        stackView.addArrangedSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// Swatch, tag name, and the state word pinned to the right edge — the
    /// same leading-label/trailing-label shape the other headers in this file
    /// use, and it needs the same `.fill` distribution to get it.
    private func addTagHeader(_ entry: TagInspectorEntry) {
        let dot = NSImageView(image: TagPalette.swatch(colorIndex: entry.colorIndex))
        // The other `TagPalette.swatch` callers hand the image to a control
        // that sizes itself to it. A bare image view has no such rule, so it
        // is pinned to the swatch's own size instead of stretching in the row.
        dot.imageScaling = .scaleNone
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
        ])

        // The name is single-line and identifies which tag the buttons below
        // act on, so it is escaped. The NOTE is not — see `addTagNote`.
        let nameLabel = NSTextField(labelWithString: DisplayEscape.escaped(entry.name))
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stateLabel = NSTextField(labelWithString: entry.stateWord)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .tertiaryLabelColor
        stateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [dot, nameLabel, stateLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6
        stackView.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// The tag's note, wrapped. A note is free text, so it can hold one
    /// unbroken token — a URL, a path, a hash — with no word break to wrap at.
    /// Lowering the compression resistance lets it shrink against the width
    /// constraint instead of breaking it.
    ///
    /// Deliberately NOT run through `DisplayEscape`, unlike every other label in
    /// this section. A note is prose the ANALYST typed into `TagSheet`, not
    /// captured data, it is the one label here that is legitimately multi-line
    /// (`maximumNumberOfLines = 0`), and escaping would turn its own paragraph
    /// breaks into `<U+000A>`. It also names no value and gates no deletion.
    private func addTagNote(_ note: String) {
        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(noteLabel)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// One captured value: a match mark, the column it was captured from, and
    /// the value itself.
    private func addTagValueRow(_ value: TagInspectorValue) {
        let mark = NSTextField(labelWithString: value.isMatched ? "\u{2713}" : "\u{2014}")
        mark.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        mark.textColor = value.isMatched ? .systemGreen : .tertiaryLabelColor

        // Escaped, like the row-detail values above and the removal sheet that
        // deletes these same tuples: a captured value is somebody else's data,
        // and this row is what the analyst reads before pressing "Remove Tag…".
        let columnLabel = NSTextField(labelWithString: DisplayEscape.escaped(value.column))
        columnLabel.font = .systemFont(ofSize: 11, weight: .medium)
        columnLabel.textColor = .secondaryLabelColor

        let displayLabel = NSTextField(labelWithString: DisplayEscape.escaped(value.display))
        displayLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        displayLabel.textColor = value.isMatched ? .labelColor : .tertiaryLabelColor
        displayLabel.lineBreakMode = .byTruncatingMiddle
        displayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let valueRow = NSStackView(views: [mark, columnLabel, displayLabel])
        valueRow.orientation = .horizontal
        valueRow.distribution = .fill
        valueRow.spacing = 6
        stackView.addArrangedSubview(valueRow)
        valueRow.translatesAutoresizingMaskIntoConstraints = false
        valueRow.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// The per-tag controls. Each button carries its tag id, so one
    /// target-action pair serves any number of entries.
    private func addTagButtons(tagId: String) {
        guard onEditTag != nil || onDeleteTag != nil else { return }
        var buttons: [NSView] = []
        if onEditTag != nil {
            buttons.append(tagButton(title: "Edit…", tagId: tagId,
                                     action: #selector(editTagClicked(_:))))
        }
        if onDeleteTag != nil {
            buttons.append(tagButton(title: "Remove Tag…", tagId: tagId,
                                     action: #selector(deleteTagClicked(_:))))
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stackView.addArrangedSubview(buttonRow)
    }

    private func tagButton(title: String, tagId: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.identifier = NSUserInterfaceItemIdentifier(tagId)
        return button
    }

    private func addTagSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stackView.addArrangedSubview(spacer)
    }

    /// The tag id rides on the button's `identifier` — one target-action pair
    /// for any number of entries, no associated objects.
    @objc private func editTagClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onEditTag?(id) }
    }

    @objc private func deleteTagClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onDeleteTag?(id) }
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        return label
    }

    private func makeFieldValueLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = color
        return label
    }

    /// Same thresholds as `SchemaTreeNode.formatCount` (≥1M → "%.1fM", ≥1K →
    /// "%.1fK", else the raw integer), minus its baked-in " rows" suffix — the
    /// inspector's own "Rows" label already supplies that context.
    private func formatRowCount(_ count: Int64?) -> String {
        guard let count else { return "\u{2014}" }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func formatByteSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "\u{2014}" }
        return Self.byteCountFormatter.string(fromByteCount: bytes)
    }

    // MARK: - Helpers

    private func makeKeyLabel(name: String, dataType: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let attrStr = NSMutableAttributedString(
            // A column name is data too — it can be a SELECT alias straight out
            // of the query, so it gets the same treatment as the value beside it.
            string: DisplayEscape.escaped(name),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        attrStr.append(NSAttributedString(
            string: " \(dataType)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ))
        label.attributedStringValue = attrStr
        label.lineBreakMode = .byTruncatingTail
        // Let the key label truncate rather than demand its full text width, so a
        // long column name can't inflate the inspector pane's fitting width. This
        // keeps the pane's width driven by the split divider, not by its content.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        return label
    }

    private func makeValueLabel(value: AnyCodable?, category: PGTypeCategory) -> NSTextField {
        let label = CopyableValueLabel(labelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        guard let value else {
            // Key missing from dict entirely — treat as NULL
            label.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
            label.copyableValue = label.stringValue
            label.textColor = .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            return label
        }

        if value.isNull {
            label.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
            label.copyableValue = label.stringValue
            label.textColor = .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            return label
        }

        if value.displayString.isEmpty {
            label.stringValue = "(empty string)"
            label.copyableValue = ""
            label.textColor = .tertiaryLabelColor
            return label
        }

        // Type-aware coloring matching ResultsDataSource.
        //
        // DISPLAY is escaped, COPY is raw — the two are assigned from different
        // sources on purpose and must not be collapsed back into one. A bidi
        // override would otherwise make this pane read as a filename the row
        // does not hold; an escaped copy would paste a corrupt indicator into
        // whatever the analyst pastes it into.
        label.stringValue = DisplayEscape.escaped(value.displayString)
        label.copyableValue = value.displayString

        switch category {
        case .numeric:
            label.textColor = .systemBlue
        case .boolean:
            let str = value.displayString.lowercased()
            let boolDisplay = AppStateManager.shared.settings.boolDisplay
            if str == "t" || str == "true" {
                // The bool words are app-owned, so display and copy agree here.
                label.stringValue = boolDisplay.trueString
                label.copyableValue = boolDisplay.trueString
                label.textColor = .systemGreen
            } else if str == "f" || str == "false" {
                label.stringValue = boolDisplay.falseString
                label.copyableValue = boolDisplay.falseString
                label.textColor = .systemRed
            } else {
                label.textColor = .labelColor
            }
        case .temporal:
            label.textColor = .systemPurple
        case .json:
            label.textColor = .systemOrange
        case .array:
            label.textColor = .secondaryLabelColor
        case .string:
            label.textColor = .labelColor
        }

        return label
    }

    private func makeStatLine(pairs: [(label: String, value: String, color: NSColor)]) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        let attrStr = NSMutableAttributedString()
        for pair in pairs {
            attrStr.append(NSAttributedString(
                string: pair.label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
            attrStr.append(NSAttributedString(
                string: pair.value,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: pair.color,
                ]
            ))
        }
        field.attributedStringValue = attrStr
        return field
    }

    // MARK: - Aggregation Model

    private struct ColumnAggregation {
        let columnName: String
        let dataType: String
        let category: PGTypeCategory
        var totalCount: Int = 0
        var nonNullCount: Int = 0
        var distinctValues: Set<String> = []
        // Numeric
        var numericMin: Double?
        var numericMax: Double?
        var numericSum: Double = 0
        // Temporal
        var earliest: String?
        var latest: String?
        // Boolean
        var trueCount: Int = 0
        var falseCount: Int = 0

        var distinctCount: Int { distinctValues.count }
        var numericAvg: Double? {
            nonNullCount > 0 && numericMin != nil ? numericSum / Double(nonNullCount) : nil
        }
    }

    private static let aggregateFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()

    private func formatAggregate(_ value: Double) -> String {
        Self.aggregateFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func computeAggregations(
        columns: [ColumnDef],
        rows: [[AnyCodable]],
        categories: [PGTypeCategory]
    ) -> [ColumnAggregation] {
        columns.enumerated().map { (index, col) in
            var agg = ColumnAggregation(
                columnName: col.name,
                dataType: col.dataType,
                category: index < categories.count ? categories[index] : .string
            )
            for row in rows {
                let value: AnyCodable? = index < row.count ? row[index] : nil
                agg.totalCount += 1

                guard let val = value, !val.isNull else { continue }
                agg.nonNullCount += 1
                agg.distinctValues.insert(val.displayString)

                switch agg.category {
                case .numeric:
                    if let d = Double(val.displayString) {
                        agg.numericMin = min(agg.numericMin ?? d, d)
                        agg.numericMax = max(agg.numericMax ?? d, d)
                        agg.numericSum += d
                    }
                case .temporal:
                    // Skip min/max for interval types — lexicographic comparison is meaningless
                    let dt = col.dataType.lowercased()
                    guard dt != "interval" else { break }
                    let s = val.displayString
                    if agg.earliest == nil || s < agg.earliest! { agg.earliest = s }
                    if agg.latest == nil || s > agg.latest! { agg.latest = s }
                case .boolean:
                    let b = val.displayString.lowercased()
                    if b == "t" || b == "true" { agg.trueCount += 1 }
                    else if b == "f" || b == "false" { agg.falseCount += 1 }
                default:
                    break
                }
            }
            return agg
        }
    }
}

// MARK: - CopyableValueLabel

private class CopyableValueLabel: NSTextField {
    /// The RAW value, for the pasteboard. Deliberately not the same string as
    /// `stringValue`, which its setter escapes for display: an analyst pastes
    /// indicators out of this pane into other systems, so the copy must be the
    /// bytes the database returned, not the `<U+XXXX>` rendering of them.
    /// The one place it is READ for display — the context-menu title — escapes
    /// it at that point instead.
    var copyableValue: String = ""
    private var savedAttributedString: NSAttributedString?
    private var restoreTimer: Timer?

    override func layout() {
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
        }
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            copyToPasteboard()
            showCopiedFeedback()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Truncate the RAW value first, then escape — escaping first and cutting
        // at 50 would slice a `<U+202E>` token in half and print the debris.
        // The menu title is display, so it is escaped; `copyValue` still puts
        // the raw `copyableValue` on the pasteboard.
        let clipped = copyableValue.count > 50
            ? String(copyableValue.prefix(50)) + "\u{2026}"
            : copyableValue
        let display = DisplayEscape.escaped(clipped)
        let item = NSMenuItem(title: "Copy \"\(display)\"", action: #selector(copyValue), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyValue() {
        copyToPasteboard()
        showCopiedFeedback()
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableValue, forType: .string)
    }

    private func showCopiedFeedback() {
        restoreTimer?.invalidate()
        savedAttributedString = attributedStringValue

        let feedback = NSMutableAttributedString(
            string: "\u{2713} Copied",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.systemGreen,
            ]
        )
        attributedStringValue = feedback

        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self, let saved = self.savedAttributedString else { return }
            self.attributedStringValue = saved
            self.savedAttributedString = nil
        }
    }
}

// MARK: - FlippedView

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
