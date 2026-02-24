import AppKit

/// Sheet for importing CSV data into a table.
class ImportDataSheet: NSViewController {

    private let filePathLabel = NSTextField(labelWithString: "No file selected")
    private let hasHeadersCheckbox = NSButton(checkboxWithTitle: "CSV file has headers", target: nil, action: nil)

    private let schema: String
    private let table: String
    private var onImport: ((String, Bool) -> Void)?
    private var selectedFilePath: String?

    init(schema: String, table: String, onImport: @escaping (String, Bool) -> Void) {
        self.schema = schema
        self.table = table
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Import Data")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "\(schema).\(table)")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        // File picker
        let fileLabel = NSTextField(labelWithString: "CSV File:")
        fileLabel.font = .systemFont(ofSize: 13)
        fileLabel.alignment = .right

        filePathLabel.lineBreakMode = .byTruncatingMiddle
        filePathLabel.textColor = .secondaryLabelColor
        filePathLabel.font = .systemFont(ofSize: 12)
        filePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let browseButton = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseFile))

        let fileRow = NSStackView(views: [filePathLabel, browseButton])
        fileRow.spacing = 8

        // Has headers checkbox (default checked)
        hasHeadersCheckbox.state = .on

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let importButton = NSButton(title: "Import", target: self, action: #selector(doImport))
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [cancelButton, importButton])
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
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: titleLabel)

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            filePathLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a CSV file to import into \(schema).\(table)"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.selectedFilePath = url.path
                self?.filePathLabel.stringValue = url.lastPathComponent
                self?.filePathLabel.textColor = .labelColor
            }
        }
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
