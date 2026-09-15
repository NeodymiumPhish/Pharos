import AppKit

/// Sheet for importing CSV data into a table.
class ImportDataSheet: NSViewController {

    private let filePathLabel = NSTextField(labelWithString: String(localized: "No file selected"))
    private let hasHeadersCheckbox = NSButton(checkboxWithTitle: String(localized: "CSV file has headers"), target: nil, action: nil)
    // Stored, not local to `loadView`, so `wireKeyViewLoop()` can reach them.
    private let browseButton = NSButton()
    private let cancelButton = NSButton()
    private let importButton = NSButton()

    private let schema: String
    private let table: String
    private var onImport: ((String, Bool) -> Void)?
    private var selectedFilePath: String?

    /// `preselectedFileURL` is the file a drop on the table node carried: the
    /// sheet then opens with that file already chosen, so the drop does not
    /// ask the user to find the same file again in an open panel.
    init(schema: String, table: String, preselectedFileURL: URL? = nil,
         onImport: @escaping (String, Bool) -> Void) {
        self.schema = schema
        self.table = table
        self.onImport = onImport
        self.selectedFilePath = preselectedFileURL?.path
        self.preselectedFileName = preselectedFileURL?.lastPathComponent
        super.init(nibName: nil, bundle: nil)
    }

    /// Held until `loadView` builds the label it belongs in.
    private let preselectedFileName: String?

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: String(localized: "Import Data"))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: DisplayEscape.escapedQualified(schema: schema, table: table))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        // File picker
        let fileLabel = NSTextField(labelWithString: String(localized: "CSV File:"))
        fileLabel.font = .systemFont(ofSize: 13)
        fileLabel.alignment = .right

        filePathLabel.lineBreakMode = .byTruncatingMiddle
        filePathLabel.textColor = .secondaryLabelColor
        filePathLabel.font = .systemFont(ofSize: 12)
        filePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        browseButton.title = String(localized: "Choose\u{2026}")
        browseButton.target = self
        browseButton.action = #selector(chooseFile)

        let fileRow = NSStackView(views: [filePathLabel, browseButton])
        fileRow.spacing = 8

        // Has headers checkbox (default checked)
        hasHeadersCheckbox.state = .on

        // Buttons
        cancelButton.title = String(localized: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("sheet.importdata.cancel")
        importButton.title = String(localized: "Import")
        importButton.target = self
        importButton.action = #selector(doImport)
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded
        importButton.setAccessibilityIdentifier("sheet.importdata.default")
        // Nothing to import until a file is chosen — by the panel, or by the
        // drop that opened this sheet.
        importButton.isEnabled = selectedFilePath != nil
        if let preselectedFileName {
            showChosenFile(named: preselectedFileName)
        }

        let buttonStack = NSStackView(views: [Self.spacer(), cancelButton, importButton])
        buttonStack.spacing = 8

        // Layout
        let grid = NSGridView(views: [
            [fileLabel, fileRow],
            [NSGridCell.emptyContentView, hasHeadersCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        let stack = NSStackView(views: [titleLabel, subtitleLabel, grid, buttonStack])
        stack.orientation = .vertical
        // `.leading` plus the width pin, not `.centerX`: an NSStackView rejects
        // `.width` outright, so every row is pinned to the stack's own width
        // instead — see NSStackView+SpanFullWidth.swift. That is what lets the
        // button row's leading spacer push Cancel/Import to the trailing edge.
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: titleLabel)
        // Called after every arranged subview is in place, since it only
        // constrains what is there when it runs. `stack` has no edgeInsets of
        // its own — its parent (the two leading/trailing constraints below)
        // supplies the 20pt side margin instead.
        stack.spanArrangedSubviewsFullWidth()

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            filePathLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    // MARK: - Key View Loop

    override func viewWillAppear() {
        super.viewWillAppear()
        // No editable text field — the CSV path is chosen through the panel,
        // not typed — so the first button is the initial responder.
        view.window?.initialFirstResponder = browseButton
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once — which silently
        // discards the explicit chain below the first time anything
        // (opening the window, a control becoming key) triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        wireKeyViewLoop()
    }

    /// Explicit, because these controls sit in NSGridView rows: AppKit's
    /// automatic key view loop follows the grid's own subview order, which
    /// does not match the row-by-row reading order the form is laid out in.
    private func wireKeyViewLoop() {
        browseButton.nextKeyView = hasHeadersCheckbox
        hasHeadersCheckbox.nextKeyView = cancelButton
        cancelButton.nextKeyView = importButton
        importButton.nextKeyView = browseButton
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

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Select a CSV file to import into \(DisplayEscape.escapedQualified(schema: schema, table: table))")

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.selectedFilePath = url.path
                self?.showChosenFile(named: url.lastPathComponent)
            }
        }
    }

    /// Shows the chosen file and enables Import. The name goes through
    /// `DisplayEscape` for the same reason the browse path does: a file name
    /// can carry a bidi override, and the label must read as the file that
    /// will actually be imported.
    private func showChosenFile(named name: String) {
        filePathLabel.stringValue = DisplayEscape.escaped(name)
        filePathLabel.textColor = .labelColor
        importButton.isEnabled = true
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func doImport() {
        guard let filePath = selectedFilePath else {
            // Shake or show error
            NSSound.beep()
            return
        }
        dismiss(nil)
        onImport?(filePath, hasHeadersCheckbox.state == .on)
    }
}
