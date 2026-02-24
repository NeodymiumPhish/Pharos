import AppKit
import UniformTypeIdentifiers

/// Sheet for exporting table data with format, column, and header options.
class ExportDataSheet: NSViewController {

    private let formatPopup = NSPopUpButton()
    private let includeHeadersCheckbox = NSButton(checkboxWithTitle: "Include headers", target: nil, action: nil)
    private let nullDisplayPopup = NSPopUpButton()
    private var columnCheckboxes: [(checkbox: NSButton, name: String)] = []
    private let columnScrollView = NSScrollView()

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

        let subtitleLabel = NSTextField(labelWithString: "\(schema).\(table)")
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
            let title = "\(col.name)  \u{2022}  \(col.dataType)"
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
        let selectAllButton = NSButton(title: "All", target: self, action: #selector(selectAllColumns))
        selectAllButton.bezelStyle = .inline
        selectAllButton.controlSize = .small
        selectAllButton.font = .systemFont(ofSize: 11)
        let deselectAllButton = NSButton(title: "None", target: self, action: #selector(deselectAllColumns))
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
        columnSection.alignment = .width
        columnSection.spacing = 4
        columnSection.translatesAutoresizingMaskIntoConstraints = false

        // Form grid
        let grid = NSGridView(views: [
            [makeLabel("Format"), formatPopup],
            [makeLabel("Headers"), includeHeadersCheckbox],
            [makeLabel("NULL values"), nullDisplayPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).width = 300
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        // Action buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let exportButton = NSButton(title: "Export\u{2026}", target: self, action: #selector(doExport))
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, exportButton])
        buttonRow.spacing = 8

        // Main layout
        let mainStack = NSStackView(views: [titleStack, grid, columnSection, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Column section fills available width
            columnSection.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 24),
            columnSection.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -24),
            columnScrollView.heightAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        return label
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
        panel.nameFieldStringValue = "\(table).\(format.fileExtension)"
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
