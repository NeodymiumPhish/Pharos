import AppKit
import UniformTypeIdentifiers

/// Sheet for exporting table data with format, column, and header options.
class ExportDataSheet: NSViewController {

    private let formatPopup = NSPopUpButton()
    private let includeHeadersCheckbox = NSButton(checkboxWithTitle: "Include headers", target: nil, action: nil)
    private let nullDisplayPopup = NSPopUpButton()
    private var columnCheckboxes: [(checkbox: NSButton, name: String)] = []
    private let columnScrollView = NSScrollView()
    // Stored, not local to `loadView`, so `wireKeyViewLoop()` can reach them.
    private let selectAllButton = NSButton()
    private let deselectAllButton = NSButton()
    private let cancelButton = NSButton()
    private let exportButton = NSButton()

    private let schema: String
    private let table: String
    private let columns: [ColumnInfo]
    private var onExport: ((ExportTableOptions) -> Void)?

    init(schema: String, table: String, columns: [ColumnInfo], onExport: @escaping (ExportTableOptions) -> Void) {
        self.schema = schema
        self.table = table
        self.columns = columns
        self.onExport = onExport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Export Data")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Escaped per PART, not on the joined pair: the dot is ours, so
        // escaping the whole string would demote each part's edge space to an
        // interior one and lose its disclosure. The raw `schema`/`table` are
        // what the export request carries.
        let subtitleLabel = NSTextField(labelWithString: DisplayEscape.escapedQualified(schema: schema, table: table))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .centerX
        titleStack.spacing = 2

        // Format popup
        for format in ExportFormat.allCases {
            formatPopup.addItem(withTitle: format.displayLabel)
            formatPopup.lastItem?.representedObject = format
        }

        // Include headers
        includeHeadersCheckbox.state = .on

        // NULL display
        nullDisplayPopup.addItem(withTitle: "Empty string")
        nullDisplayPopup.lastItem?.tag = 0
        nullDisplayPopup.addItem(withTitle: "NULL")
        nullDisplayPopup.lastItem?.tag = 1

        // Column checkboxes in a scrollable area
        let columnStack = NSStackView()
        columnStack.orientation = .vertical
        columnStack.alignment = .leading
        columnStack.spacing = 2
        columnStack.translatesAutoresizingMaskIntoConstraints = false

        for col in columns {
            // Display only: the selected columns are read from the tuple's
            // `name`, never from the button's title.
            let title = "\(DisplayEscape.escaped(col.name))  \u{2022}  \(DisplayEscape.escaped(col.dataType))"
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            checkbox.state = .on
            checkbox.font = .systemFont(ofSize: 12)
            columnCheckboxes.append((checkbox: checkbox, name: col.name))
            columnStack.addArrangedSubview(checkbox)
        }

        let clipView = NSClipView()
        clipView.documentView = columnStack
        columnScrollView.contentView = clipView
        columnScrollView.hasVerticalScroller = true
        columnScrollView.autohidesScrollers = true
        columnScrollView.borderType = .bezelBorder
        columnScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Column header with All/None buttons
        let columnsHeaderLabel = NSTextField(labelWithString: "Columns")
        columnsHeaderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        columnsHeaderLabel.textColor = .secondaryLabelColor
        selectAllButton.title = "All"
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllColumns)
        selectAllButton.bezelStyle = .inline
        selectAllButton.controlSize = .small
        selectAllButton.font = .systemFont(ofSize: 11)
        deselectAllButton.title = "None"
        deselectAllButton.target = self
        deselectAllButton.action = #selector(deselectAllColumns)
        deselectAllButton.bezelStyle = .inline
        deselectAllButton.controlSize = .small
        deselectAllButton.font = .systemFont(ofSize: 11)

        let columnsHeader = NSStackView(views: [columnsHeaderLabel, NSView(), selectAllButton, deselectAllButton])
        columnsHeader.orientation = .horizontal
        columnsHeader.spacing = 4
        columnsHeader.translatesAutoresizingMaskIntoConstraints = false
        // Make the spacer view expand to push buttons to the right
        columnsHeader.setHuggingPriority(.defaultLow, for: .horizontal)

        // Column section (header + scroll view)
        let columnSection = NSStackView(views: [columnsHeader, columnScrollView])
        columnSection.orientation = .vertical
        // `.leading` plus the width pin, not `.width`, which an NSStackView
        // rejects outright — see NSStackView+SpanFullWidth.swift. Both rows here
        // must span: the header's spacer is what carries All/None to the
        // trailing edge, and the scroll view holds the column list. They happen
        // to fill today, so nothing looked wrong; that is what made it latent.
        columnSection.alignment = .leading
        columnSection.spacing = 4
        columnSection.spanArrangedSubviewsFullWidth()
        columnSection.translatesAutoresizingMaskIntoConstraints = false

        // Form grid
        let grid = NSGridView(views: [
            [NSTextField.formLabel("Format"), formatPopup],
            [NSTextField.formLabel("Headers"), includeHeadersCheckbox],
            [NSTextField.formLabel("NULL values"), nullDisplayPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).width = 300
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        // Action buttons
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.title = "Export\u{2026}"
        exportButton.target = self
        exportButton.action = #selector(doExport)
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [Self.spacer(), cancelButton, exportButton])
        buttonRow.spacing = 8

        // Main layout
        let mainStack = NSStackView(views: [titleStack, grid, columnSection, buttonRow])
        mainStack.orientation = .vertical
        // `.leading` plus the width pin, not `.centerX`: an NSStackView rejects
        // `.width` outright, so every row is pinned to the stack's own width
        // instead — see NSStackView+SpanFullWidth.swift. That is what lets the
        // button row's leading spacer push Cancel/Export to the trailing edge,
        // and it now supplies columnSection's width too, so the leading/
        // trailing pair that used to do that job by hand is gone rather than
        // duplicated. titleStack keeps its own `.centerX` alignment, so the
        // title and subtitle stay centered as a block even though the row
        // around them now spans full width.
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        mainStack.spanArrangedSubviewsFullWidth()
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            columnScrollView.heightAnchor.constraint(equalToConstant: 160),
        ])
    }

    // MARK: - Layout Helpers

    /// An empty view that takes the slack in the button row, so the buttons
    /// after it sit at the trailing edge. A plain NSView would not give way,
    /// because its hugging priority matches the buttons'.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    // MARK: - Key View Loop

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.initialFirstResponder = formatPopup
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once — which silently
        // discards the explicit chain below the first time anything
        // (opening the window, a control becoming key) triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        wireKeyViewLoop()
    }

    /// Explicit, because the format/headers/NULL controls sit in NSGridView
    /// rows — AppKit's automatic key view loop follows the grid's own subview
    /// order, not the row-by-row reading order the form is laid out in — and
    /// because the column checkboxes are built one per column, so their chain
    /// has to be assembled at runtime rather than named field by field.
    private func wireKeyViewLoop() {
        formatPopup.nextKeyView = includeHeadersCheckbox
        includeHeadersCheckbox.nextKeyView = nullDisplayPopup
        nullDisplayPopup.nextKeyView = selectAllButton
        selectAllButton.nextKeyView = deselectAllButton

        var previous: NSView = deselectAllButton
        for (checkbox, _) in columnCheckboxes {
            previous.nextKeyView = checkbox
            previous = checkbox
        }
        previous.nextKeyView = cancelButton
        cancelButton.nextKeyView = exportButton
        exportButton.nextKeyView = formatPopup
    }

    @objc private func selectAllColumns() {
        for (checkbox, _) in columnCheckboxes {
            checkbox.state = .on
        }
    }

    @objc private func deselectAllColumns() {
        for (checkbox, _) in columnCheckboxes {
            checkbox.state = .off
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func doExport() {
        guard let format = formatPopup.selectedItem?.representedObject as? ExportFormat else { return }

        let selectedColumns = columnCheckboxes
            .filter { $0.checkbox.state == .on }
            .map { $0.name }

        guard !selectedColumns.isEmpty else {
            NSSound.beep()
            return
        }

        let nullAsEmpty = nullDisplayPopup.indexOfSelectedItem == 0

        // Show save panel
        let panel = NSSavePanel()
        // The table name is a server-supplied string, so it goes through the
        // app's one filename sanitiser before it reaches the save panel. The
        // extension stays outside it — it is an app constant, and sanitising
        // it would be noise.
        panel.nameFieldStringValue = "\(SavedQueryFilename.sanitize(table)).\(format.fileExtension)"
        panel.message = "Choose where to save the exported data"
        if let contentType = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        dismiss(nil)

        guard let window = NSApp.mainWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                let options = ExportTableOptions(
                    schemaName: schema, tableName: table,
                    columns: selectedColumns,
                    includeHeaders: includeHeadersCheckbox.state == .on,
                    nullAsEmpty: nullAsEmpty,
                    filePath: url.path,
                    format: format
                )
                onExport?(options)
            }
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let options = ExportTableOptions(
                schemaName: self.schema, tableName: self.table,
                columns: selectedColumns,
                includeHeaders: self.includeHeadersCheckbox.state == .on,
                nullAsEmpty: nullAsEmpty,
                filePath: url.path,
                format: format
            )
            self.onExport?(options)
        }
    }
}
