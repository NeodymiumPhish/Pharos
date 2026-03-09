import AppKit

/// Sheet showing the SQL query and execution summary for a result tab.
/// Provides Copy and Save actions for the query.
class QueryDetailSheet: NSViewController {

    private let resultTab: ResultTab
    private var onSaveQuery: ((String) -> Void)?

    init(resultTab: ResultTab, onSaveQuery: @escaping (String) -> Void) {
        self.resultTab = resultTab
        self.onSaveQuery = onSaveQuery
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Query Detail")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Action buttons row (Copy + Save)
        let copyButton = NSButton(title: "Copy Query", target: self, action: #selector(copyQuery))
        copyButton.bezelStyle = .rounded
        let copyConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(copyConfig)
        copyButton.imagePosition = .imageLeading

        let saveButton = NSButton(title: "Save Query", target: self, action: #selector(saveQuery))
        saveButton.bezelStyle = .rounded
        let saveConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(saveConfig)
        saveButton.imagePosition = .imageLeading

        let actionRow = NSStackView(views: [copyButton, saveButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        // SQL text view (read-only, monospaced)
        let sqlScrollView = NSScrollView()
        sqlScrollView.hasVerticalScroller = true
        sqlScrollView.hasHorizontalScroller = false
        sqlScrollView.borderType = .bezelBorder
        sqlScrollView.drawsBackground = true

        let sqlTextView = NSTextView()
        sqlTextView.isEditable = false
        sqlTextView.isSelectable = true
        sqlTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sqlTextView.string = resultTab.sql
        sqlTextView.textContainerInset = NSSize(width: 8, height: 8)
        sqlTextView.isVerticallyResizable = true
        sqlTextView.isHorizontallyResizable = false
        sqlTextView.autoresizingMask = [.width]
        sqlTextView.textContainer?.widthTracksTextView = true
        sqlTextView.backgroundColor = .textBackgroundColor

        sqlScrollView.documentView = sqlTextView
        sqlScrollView.translatesAutoresizingMaskIntoConstraints = false
        sqlScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // Summary info
        let summaryView = buildSummaryView()

        // Done button
        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [doneButton])
        buttonRow.orientation = .horizontal

        // Main layout
        let mainStack = NSStackView(views: [titleLabel, actionRow, sqlScrollView, summaryView, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // SQL scroll view should stretch to fill
        NSLayoutConstraint.activate([
            sqlScrollView.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 20),
            sqlScrollView.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20),
            summaryView.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 20),
            summaryView.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20),
        ])

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Summary

    private func buildSummaryView() -> NSView {
        var rows: [(String, String)] = []

        // Execution time
        let timeMs = resultTab.executionTimeMs
        if timeMs > 0 {
            let formatted = timeMs >= 1000
                ? String(format: "%.2f s", Double(timeMs) / 1000.0)
                : "\(timeMs) ms"
            rows.append(("Execution Time", formatted))
        }

        // Row count / rows affected
        if let result = resultTab.queryResult {
            var detail = "\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")"
            if result.hasMore { detail += " (truncated)" }
            rows.append(("Rows Returned", detail))
            rows.append(("Columns", "\(result.columns.count)"))
        } else if let execResult = resultTab.executeResult {
            rows.append(("Rows Affected", "\(execResult.rowsAffected)"))
        }

        // Timestamp
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        rows.append(("Executed At", formatter.string(from: resultTab.timestamp)))

        // Source lines
        if resultTab.lineRange.count == 1 {
            rows.append(("Source Line", "L\(resultTab.lineRange.lowerBound)"))
        } else {
            rows.append(("Source Lines", "L\(resultTab.lineRange.lowerBound)–\(resultTab.lineRange.upperBound)"))
        }

        if resultTab.isStale {
            rows.append(("Status", "Stale (editor modified since execution)"))
        }

        // Build grid
        let gridRows: [[NSView]] = rows.map { label, value in
            let labelField = NSTextField(labelWithString: label + ":")
            labelField.font = .systemFont(ofSize: 12, weight: .medium)
            labelField.textColor = .secondaryLabelColor
            labelField.alignment = .right

            let valueField = NSTextField(labelWithString: value)
            valueField.font = .systemFont(ofSize: 12)
            valueField.textColor = .labelColor
            valueField.lineBreakMode = .byTruncatingTail

            return [labelField, valueField]
        }

        let grid = NSGridView(views: gridRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        return grid
    }

    // MARK: - Actions

    @objc private func copyQuery() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTab.sql, forType: .string)

        // Brief visual feedback — flash the button title
        if let button = view.findSubview(ofType: NSButton.self, where: { $0.title == "Copy Query" }) {
            button.title = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                button.title = "Copy Query"
            }
        }
    }

    @objc private func saveQuery() {
        let sql = resultTab.sql
        let callback = onSaveQuery
        dismiss(nil)
        callback?(sql)
    }

    @objc private func dismissSheet() {
        dismiss(nil)
    }
}

// MARK: - View Finder Helper

private extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type, where predicate: (T) -> Bool) -> T? {
        for sub in subviews {
            if let match = sub as? T, predicate(match) { return match }
            if let found = sub.findSubview(ofType: type, where: predicate) { return found }
        }
        return nil
    }
}
