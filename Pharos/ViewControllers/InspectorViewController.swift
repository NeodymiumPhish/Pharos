import AppKit

/// Inspector view controller for the right pane.
/// Shows single-row detail when one row is selected, placeholder otherwise.
class InspectorViewController: NSViewController {

    private let noSelectionLabel = NSTextField(labelWithString: "No Selection")
    private var scrollView = NSScrollView()
    private var stackView = NSStackView()
    private var currentRowNumber: Int?

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

    func showNoSelection() {
        currentRowNumber = nil
        scrollView.isHidden = true
        noSelectionLabel.stringValue = "No Selection"
        noSelectionLabel.isHidden = false
    }

    func showRowDetail(
        columns: [ColumnDef],
        row: [String: AnyCodable],
        rowNumber: Int,
        totalRows: Int,
        columnCategories: [String: PGTypeCategory]
    ) {
        // Skip rebuild if same row
        if currentRowNumber == rowNumber { return }
        currentRowNumber = rowNumber

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

        // Column key-value pairs
        for colDef in columns {
            let category = columnCategories[colDef.name] ?? .string
            let keyLabel = makeKeyLabel(name: colDef.name, dataType: colDef.dataType)
            let valueLabel = makeValueLabel(value: row[colDef.name], category: category)

            stackView.addArrangedSubview(keyLabel)
            stackView.addArrangedSubview(valueLabel)

            // Add spacer between column groups
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
            stackView.addArrangedSubview(spacer)
        }
    }

    func showAggregation(
        columns: [ColumnDef],
        rows: [[String: AnyCodable]],
        selectionCount: Int,
        columnCategories: [String: PGTypeCategory]
    ) {
        // Stub for Plan 02 — show selection count
        currentRowNumber = nil
        scrollView.isHidden = true
        noSelectionLabel.stringValue = "\(selectionCount) rows selected"
        noSelectionLabel.isHidden = false
    }

    // MARK: - Helpers

    private func makeKeyLabel(name: String, dataType: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let attrStr = NSMutableAttributedString(
            string: name,
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
        return label
    }

    private func makeValueLabel(value: AnyCodable?, category: PGTypeCategory) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 200
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        guard let value else {
            // Key missing from dict entirely — treat as NULL
            label.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
            label.textColor = .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            return label
        }

        if value.isNull {
            label.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
            label.textColor = .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            return label
        }

        if value.displayString.isEmpty {
            label.stringValue = "(empty string)"
            label.textColor = .tertiaryLabelColor
            return label
        }

        // Type-aware coloring matching ResultsDataSource
        label.stringValue = value.displayString

        switch category {
        case .numeric:
            label.textColor = .systemBlue
        case .boolean:
            let str = value.displayString.lowercased()
            let boolDisplay = AppStateManager.shared.settings.boolDisplay
            if str == "t" || str == "true" {
                label.stringValue = boolDisplay.trueString
                label.textColor = .systemGreen
            } else if str == "f" || str == "false" {
                label.stringValue = boolDisplay.falseString
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
        rows: [[String: AnyCodable]],
        categories: [String: PGTypeCategory]
    ) -> [ColumnAggregation] {
        columns.map { col in
            var agg = ColumnAggregation(
                columnName: col.name,
                dataType: col.dataType,
                category: categories[col.name] ?? .string
            )
            for row in rows {
                let value = row[col.name]
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

// MARK: - FlippedView

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
