import AppKit

/// Add Values…: paste or type values, one per line; each ready line becomes a
/// rule with one condition, its type detected (`TagValueImport`). A preview
/// says, line by line, the type each value will match as, and which lines are
/// left out — a repeat, a value the tag already has, or one the matcher would
/// refuse.
final class TagAddValuesSheet: NSViewController, NSTextViewDelegate {

    private let existing: [[TagCondition]]
    private let onAdd: ([TagCondition]) -> Void
    private(set) var lines: [TagValueImport.Line] = []

    let textView = NSTextView()
    let previewTable = NSTableView()
    let summaryLabel = NSTextField(labelWithString: "")
    let addButton = NSButton(title: "", target: nil, action: nil)
    let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    init(existing: [[TagCondition]], onAdd: @escaping ([TagCondition]) -> Void) {
        self.existing = existing
        self.onAdd = onAdd
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        view = root

        let title = NSTextField(labelWithString: String(localized: "Add Values"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: String(localized:
            "Paste or type one value per line: addresses, CIDR ranges, numbers, dates, UUIDs or text. A value with * or ? matches as a pattern. Each line becomes a rule."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Values, one per line"))
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder

        for (id, title, width) in [("value", String(localized: "Value"), 220.0),
                                   ("type", String(localized: "Matches as"), 150.0),
                                   ("status", String(localized: "Status"), 180.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            previewTable.addTableColumn(column)
        }
        previewTable.dataSource = self
        previewTable.delegate = self
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.setAccessibilityLabel(String(localized: "Preview"))
        let previewScroll = NSScrollView()
        previewScroll.documentView = previewTable
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.keyEquivalent = "\r"
        addButton.bezelStyle = .rounded
        let footer = NSStackView(views: [summaryLabel, cancelButton, addButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [title, hint, textScroll, previewScroll, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            hint.widthAnchor.constraint(equalTo: column.widthAnchor),
            textScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            previewScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            textScroll.heightAnchor.constraint(equalToConstant: 140),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) { refresh() }

    /// Re-read the text: the preview, the summary, and the Add button.
    func refresh() {
        lines = TagValueImport.lines(from: textView.string, existing: existing)
        previewTable.reloadData()
        let ready = TagValueImport.readyConditions(lines).count
        let left = lines.count - ready
        addButton.title = ready == 1 ? String(localized: "Add 1 Rule") : String(localized: "Add \(ready) Rules")
        addButton.isEnabled = ready > 0
        summaryLabel.stringValue = lines.isEmpty
            ? String(localized: "No values yet.")
            : left == 0 ? String(localized: "Every line becomes a rule.")
            : String(localized: "\(left) line(s) left out — see Status.")
    }

    @objc private func addTapped(_ sender: Any?) {
        let conditions = TagValueImport.readyConditions(lines)
        guard !conditions.isEmpty else { return }
        onAdd(conditions)
        dismiss(nil)
    }

    @objc private func cancelTapped(_ sender: Any?) { dismiss(nil) }

    static func statusText(_ status: TagValueImport.Line.Status) -> String {
        switch status {
        case .ready: return String(localized: "New rule")
        case .repeated: return String(localized: "Repeated above")
        case .alreadyInTag: return String(localized: "Already in this tag")
        case .invalid(let reason): return reason
        }
    }
}

extension TagAddValuesSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let line = lines[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "value": text = DisplayEscape.escaped(line.text)
        case "type": text = line.typeLabel
        default: text = Self.statusText(line.status)
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "status" {
            switch line.status {
            case .ready: label.textColor = .labelColor
            case .invalid: label.textColor = .systemRed
            default: label.textColor = .secondaryLabelColor
            }
        }
        return label
    }
}
