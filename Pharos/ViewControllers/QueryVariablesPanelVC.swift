import AppKit

/// Right-docked panel listing a tab's query variables. Styled to match the
/// app's sidebar/inspector idiom: sidebar-material vibrancy, a small secondary
/// section header, compact fields that stretch to the panel width, and semantic
/// colors so it reads as a first-party docked panel in light and dark.
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
        // The panel is docked inside the white content area (beside the editor),
        // so it uses the content background — matching the editor/inspector —
        // rather than the sidebar's edge vibrancy. `updateLayer` re-resolves the
        // semantic color on light/dark changes (a plain cgColor would go stale).
        let container = PanelBackgroundView()
        container.wantsLayer = true
        self.view = container

        // Leading hairline so the panel edge reads cleanly against the editor.
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false

        // Header: small secondary title + borderless add button (inspector idiom).
        let title = NSTextField(labelWithString: "Variables")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add variable")
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.controlSize = .small
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "Add variable"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(addButton)

        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Rows: vertical stack whose children stretch to the panel width.
        // (`.width` alignment stretches arranged subviews on a vertical stack —
        // `.fill` is not valid on NSStackView.alignment.)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 12
        rowsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        scrollView.contentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(edge)
        container.addSubview(header)
        container.addSubview(headerSeparator)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 18),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
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
            let empty = NSTextField(labelWithString: "No variables — click + to add one.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 2
            rowsStack.addArrangedSubview(empty)
        }
    }

    private func makeRow(for id: UUID) -> NSView {
        let variable = variables.first(where: { $0.id == id })

        // Name line: {{ name }}                          🗑
        let braceLead = Self.braceLabel("{{")
        let braceTrail = Self.braceLabel("}}")

        let nameField = NSTextField()
        nameField.placeholderString = "name"
        nameField.stringValue = variable?.name ?? ""
        nameField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        nameField.controlSize = .small
        nameField.identifier = NSUserInterfaceItemIdentifier("name:\(id.uuidString)")
        nameField.delegate = self
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton()
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete variable")
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.controlSize = .small
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.toolTip = "Delete variable"
        deleteButton.identifier = NSUserInterfaceItemIdentifier("delete:\(id.uuidString)")
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let nameLine = NSStackView(views: [braceLead, nameField, braceTrail, deleteButton])
        nameLine.orientation = .horizontal
        nameLine.spacing = 3
        nameLine.distribution = .fill

        // Value line: value                              [Type ▾]
        let valueField = NSTextField()
        valueField.placeholderString = "value"
        valueField.stringValue = variable?.value ?? ""
        valueField.font = .systemFont(ofSize: 11)
        valueField.controlSize = .small
        valueField.identifier = NSUserInterfaceItemIdentifier("value:\(id.uuidString)")
        valueField.delegate = self
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.translatesAutoresizingMaskIntoConstraints = false

        let typePopup = NSPopUpButton()
        for t in VariableType.allCases { typePopup.addItem(withTitle: t.displayName) }
        if let current = variable?.type, let idx = VariableType.allCases.firstIndex(of: current) {
            typePopup.selectItem(at: idx)
        }
        typePopup.controlSize = .small
        typePopup.font = .systemFont(ofSize: 11)
        typePopup.identifier = NSUserInterfaceItemIdentifier("type:\(id.uuidString)")
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        typePopup.setContentHuggingPriority(.required, for: .horizontal)
        typePopup.translatesAutoresizingMaskIntoConstraints = false

        let valueLine = NSStackView(views: [valueField, typePopup])
        valueLine.orientation = .horizontal
        valueLine.spacing = 4
        valueLine.distribution = .fill

        let row = NSStackView(views: [nameLine, valueLine])
        row.orientation = .vertical
        row.alignment = .width
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static func braceLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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

/// Solid content-background panel that tracks light/dark. Uses `updateLayer`
/// (not a one-shot `layer.backgroundColor = ....cgColor`) so the semantic color
/// is re-resolved whenever the effective appearance changes.
private final class PanelBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
