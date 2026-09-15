import AppKit

/// Sheet showing the SQL query and execution summary for a result tab.
/// Provides Copy and Save actions for the query.
class QueryDetailSheet: NSViewController {

    private let resultTab: ResultTab
    private var onSaveQuery: ((String) -> Void)?
    // Stored, not local to `loadView`, so `wireKeyViewLoop()` can reach them.
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let sqlTextView = NSTextView.disclosingHostileScalars()
    private let doneButton = NSButton()

    /// Held once so the initial title, the "did this button just flash a
    /// confirmation" lookup, and the reset after the flash all agree — even
    /// once this string is something other than the English literal here.
    private static let copyQueryTitle = String(localized: "Copy Query")

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
        let titleLabel = NSTextField(labelWithString: String(localized: "Query Detail"))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Action buttons row (Copy + Save)
        copyButton.title = Self.copyQueryTitle
        copyButton.target = self
        copyButton.action = #selector(copyQuery)
        copyButton.bezelStyle = .rounded
        let copyConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: String(localized: "Copy"))?
            .withSymbolConfiguration(copyConfig)
        copyButton.imagePosition = .imageLeading

        saveButton.title = String(localized: "Save Query")
        saveButton.target = self
        saveButton.action = #selector(saveQuery)
        saveButton.bezelStyle = .rounded
        let saveConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: String(localized: "Save"))?
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

        // Disclosing stack, not a stock one: this pane shows the tab's raw SQL
        // and has a Copy action, so escaping the display would either corrupt
        // what Copy yields or diverge from it. See
        // `NSTextView.disclosingHostileScalars()`'s doc comment.
        sqlTextView.isEditable = false
        sqlTextView.isSelectable = true
        sqlTextView.isRichText = false
        sqlTextView.writingToolsBehavior = .none
        sqlTextView.isContinuousSpellCheckingEnabled = false
        sqlTextView.isGrammarCheckingEnabled = false
        sqlTextView.isAutomaticSpellingCorrectionEnabled = false
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
        doneButton.title = String(localized: "Done")
        doneButton.target = self
        doneButton.action = #selector(dismissSheet)
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [Self.spacer(), doneButton])
        buttonRow.orientation = .horizontal

        // Main layout
        let mainStack = NSStackView(views: [titleLabel, actionRow, sqlScrollView, summaryView, buttonRow])
        mainStack.orientation = .vertical
        // `.leading` plus the width pin, not `.centerX`: an NSStackView rejects
        // `.width` outright, so every row is pinned to the stack's own width
        // instead — see NSStackView+SpanFullWidth.swift. That is what lets the
        // button row's leading spacer push Done to the trailing edge, and it
        // now supplies sqlScrollView's and summaryView's width too, so the
        // leading/trailing pairs that used to do that job by hand are gone
        // rather than duplicated. actionRow is left as it was — its two
        // buttons stay packed at the leading edge.
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.spanArrangedSubviewsFullWidth()
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Layout Helpers

    /// An empty view that takes the slack in the button row, so the button
    /// after it sits at the trailing edge. A plain NSView would not give way,
    /// because its hugging priority matches the button's.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    // MARK: - Key View Loop

    override func viewWillAppear() {
        super.viewWillAppear()
        // No editable field on this sheet — every control is a button or a
        // read-only view — so the first button is the initial responder.
        view.window?.initialFirstResponder = copyButton
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once, as testing against a
        // live build showed — which silently discards the explicit chain
        // below the first time anything triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        copyButton.nextKeyView = saveButton
        saveButton.nextKeyView = sqlTextView
        sqlTextView.nextKeyView = doneButton
        doneButton.nextKeyView = copyButton
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
            rows.append((String(localized: "Execution Time"), formatted))
        }

        // Row count / rows affected
        if let result = resultTab.queryResult {
            var detail = CountedNounText.phrase(result.rowCount, "row")
            if result.hasMore { detail += " (truncated)" }
            rows.append((String(localized: "Rows Returned"), detail))
            rows.append((String(localized: "Columns"), "\(result.columns.count)"))
        } else if let execResult = resultTab.executeResult {
            rows.append((String(localized: "Rows Affected"), "\(execResult.rowsAffected)"))
        }

        // Timestamp
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        rows.append((String(localized: "Executed At"), formatter.string(from: resultTab.timestamp)))

        // Source lines
        if resultTab.lineRange.count == 1 {
            rows.append((String(localized: "Source Line"), "L\(resultTab.lineRange.lowerBound)"))
        } else {
            rows.append((String(localized: "Source Lines"), "L\(resultTab.lineRange.lowerBound)–\(resultTab.lineRange.upperBound)"))
        }

        if resultTab.isStale {
            rows.append((String(localized: "Status"), String(localized: "Stale (editor modified since execution)")))
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
        if let button = view.findSubview(ofType: NSButton.self, where: { $0.title == Self.copyQueryTitle }) {
            button.title = String(localized: "Copied!")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                button.title = Self.copyQueryTitle
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
