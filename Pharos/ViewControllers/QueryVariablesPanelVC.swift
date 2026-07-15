import AppKit

/// Right-docked panel listing a tab's query variables.
final class QueryVariablesPanelVC: NSViewController {

    /// Called whenever the variable set changes (add / delete / edit).
    var onChange: (([QueryVariable]) -> Void)?

    private(set) var variables: [QueryVariable] = []
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()

    /// Replace the displayed variables (e.g. on tab switch). Rebuilds rows.
    func setVariables(_ vars: [QueryVariable]) {
        variables = vars
        rebuildRows()
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        self.view = container

        // Header: title + add button
        let title = NSTextField(labelWithString: "Variables")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add variable")
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.toolTip = "Add variable"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(addButton)

        // Rows in a vertical stack inside a scroll view
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        scrollView.contentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Left-edge separator so the panel reads as docked
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(scrollView)
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 22),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rowsStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])

        rebuildRows()
    }

    // MARK: - Rows

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for variable in variables {
            rowsStack.addArrangedSubview(makeRow(for: variable.id))
        }
        if variables.isEmpty {
            let empty = NSTextField(labelWithString: "No variables.\nClick + to add one.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.maximumNumberOfLines = 2
            rowsStack.addArrangedSubview(empty)
        }
    }

    private func makeRow(for id: UUID) -> NSView {
        let braceLead = NSTextField(labelWithString: "{{")
        braceLead.textColor = .tertiaryLabelColor
        let nameField = NSTextField()
        nameField.placeholderString = "name"
        nameField.stringValue = variables.first(where: { $0.id == id })?.name ?? ""
        nameField.identifier = NSUserInterfaceItemIdentifier("name:\(id.uuidString)")
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        let braceTrail = NSTextField(labelWithString: "}}")
        braceTrail.textColor = .tertiaryLabelColor

        let valueField = NSTextField()
        valueField.placeholderString = "value"
        valueField.stringValue = variables.first(where: { $0.id == id })?.value ?? ""
        valueField.identifier = NSUserInterfaceItemIdentifier("value:\(id.uuidString)")
        valueField.delegate = self
        valueField.translatesAutoresizingMaskIntoConstraints = false

        let typePopup = NSPopUpButton()
        for t in VariableType.allCases { typePopup.addItem(withTitle: t.displayName) }
        if let current = variables.first(where: { $0.id == id })?.type,
           let idx = VariableType.allCases.firstIndex(of: current) {
            typePopup.selectItem(at: idx)
        }
        typePopup.identifier = NSUserInterfaceItemIdentifier("type:\(id.uuidString)")
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        typePopup.controlSize = .small
        typePopup.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton()
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.identifier = NSUserInterfaceItemIdentifier("delete:\(id.uuidString)")
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSStackView(views: [braceLead, nameField, braceTrail, deleteButton])
        nameRow.orientation = .horizontal
        nameRow.spacing = 2
        let controlsRow = NSStackView(views: [valueField, typePopup])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 4

        let row = NSStackView(views: [nameRow, controlsRow])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            typePopup.widthAnchor.constraint(equalToConstant: 84),
        ])
        return row
    }

    private static func id(from identifier: NSUserInterfaceItemIdentifier?, prefix: String) -> UUID? {
        guard let raw = identifier?.rawValue, raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }

    // MARK: - Actions

    @objc private func addTapped() {
        variables.append(QueryVariable(name: "", value: "", type: .literal))
        rebuildRows()
        onChange?(variables)
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let id = Self.id(from: sender.identifier, prefix: "delete:") else { return }
        variables.removeAll { $0.id == id }
        rebuildRows()
        onChange?(variables)
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        guard let id = Self.id(from: sender.identifier, prefix: "type:"),
              let varIdx = variables.firstIndex(where: { $0.id == id }) else { return }
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < VariableType.allCases.count else { return }
        variables[varIdx].type = VariableType.allCases[idx]
        onChange?(variables)
    }
}

extension QueryVariablesPanelVC: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let id = Self.id(from: field.identifier, prefix: "name:"),
           let idx = variables.firstIndex(where: { $0.id == id }) {
            variables[idx].name = field.stringValue
            onChange?(variables)
        } else if let id = Self.id(from: field.identifier, prefix: "value:"),
                  let idx = variables.firstIndex(where: { $0.id == id }) {
            variables[idx].value = field.stringValue
            onChange?(variables)
        }
    }
}

/// Flipped clip view so the rows stack grows top-down inside the scroll view.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
