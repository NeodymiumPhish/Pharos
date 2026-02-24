import AppKit

/// Sheet for cloning a table's DDL (structure) with optional data.
class CloneTableSheet: NSViewController {

    private let nameField = NSTextField()
    private let includeDataCheckbox = NSButton(checkboxWithTitle: "Include data", target: nil, action: nil)

    private let schema: String
    private let table: String
    private var onClone: ((String, Bool) -> Void)?

    init(schema: String, table: String, onClone: @escaping (String, Bool) -> Void) {
        self.schema = schema
        self.table = table
        self.onClone = onClone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Clone Table")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "\(schema).\(table)")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        // Name field
        let nameLabel = NSTextField(labelWithString: "New table name:")
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.alignment = .right
        nameField.placeholderString = "table_name"
        nameField.stringValue = "\(table)_copy"

        // Include data checkbox (default unchecked — structure only)
        includeDataCheckbox.state = .off

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        let cloneButton = NSButton(title: "Clone", target: self, action: #selector(doClone))
        cloneButton.keyEquivalent = "\r"
        cloneButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [cancelButton, cloneButton])
        buttonStack.spacing = 8

        // Layout
        let grid = NSGridView(views: [
            [nameLabel, nameField],
            [NSGridCell.emptyContentView, includeDataCheckbox],
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
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func doClone() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        dismiss(nil)
        onClone?(name, includeDataCheckbox.state == .on)
    }
}
