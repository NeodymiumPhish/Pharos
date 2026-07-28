import AppKit

/// The variables panel's detail level: everything about one variable. The list
/// level is read-only, so this is the only place a name, type, or value is
/// edited. Edits apply live (as the panel has always behaved) — there is no
/// save/cancel model, and therefore no way to lose work by navigating back.
final class VariableDetailVC: NSViewController {

    /// Fired on every keystroke / type change with the updated variable.
    var onChange: ((QueryVariable) -> Void)?
    var onDelete: (() -> Void)?
    /// Back chevron or Escape.
    var onBack: (() -> Void)?

    private(set) var variable: QueryVariable

    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    // `VariableValueTextView()` — the parameterless convenience init builds its
    // own TextKit stack. Do NOT use `init(frame:textContainer:)` with a nil
    // container: it leaves textStorage/layoutManager/textContainer all nil and
    // the view then silently discards every assignment to `string`.
    private let valueTextView = VariableValueTextView()
    private let scrollView = NSScrollView()
    private let captionLabel = NSTextField(labelWithString: "")
    /// Duplicate-name note, hidden unless this variable shares its name with
    /// another row. Sits directly under the header so it reads as a comment on
    /// the name field above it.
    private let duplicationLabel = NSTextField(labelWithString: "")
    private let editorContainer = EditorBackgroundView()
    private var gutter: LineNumberGutter?

    init(variable: QueryVariable) {
        self.variable = variable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View

    override func loadView() {
        let container = NSView()
        self.view = container

        // Header — back · name · type · delete. Mirrors a list row's
        // name-leading / type-trailing layout so the two levels rhyme.
        let backButton = NSButton()
        backButton.image = NSImage(
            systemSymbolName: "chevron.left", accessibilityDescription: "Back to variables"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.contentTintColor = .controlAccentColor
        backButton.toolTip = "Back to variables"
        backButton.target = self
        backButton.action = #selector(backTapped)

        nameField.placeholderString = "name"
        nameField.stringValue = variable.name
        nameField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        nameField.textColor = .systemIndigo
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self

        for type in VariableType.allCases { typePopup.addItem(withTitle: type.displayName) }
        if let index = VariableType.allCases.firstIndex(of: variable.type) {
            typePopup.selectItem(at: index)
        }
        typePopup.controlSize = .small
        typePopup.font = .systemFont(ofSize: 10)
        typePopup.isBordered = false
        // Kept out of the key-view loop so Tab moves name → value without
        // stranding focus on a popup between the two text controls.
        typePopup.refusesFirstResponder = true
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        let deleteButton = NSButton()
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete variable")
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.controlSize = .small
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.toolTip = "Delete variable"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        let header = NSStackView(views: [backButton, nameField, typePopup, deleteButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.distribution = .fill
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false

        // Measured directly (see PharosTests/VariableDetailVCTests.swift):
        // `NSBox(boxType: .separator)` with an explicit `heightAnchor == 1`
        // constraint — the form the plan originally specified here — still
        // resolves to 5pt tall in this view's actual layout, not 1pt. An isolated
        // probe of the same shape measured 1pt, so the mechanism is unresolved —
        // plausibly the same settle-timing effect the harness documents (stack
        // geometry here needs a second layout pass before it is final), or
        // something about this assembly. Rather than chase it: a layer-backed view
        // cannot acquire a height by accident, since nothing but one explicit
        // constraint can influence it, and the harness asserts the 1pt result.
        // `VariableListView` hit the same "unconstrained separator measures
        // 5pt" problem for its row hairlines and fixed it with a plain
        // layer-backed 1pt view instead of `NSBox` — used here for the same
        // reason: a layer-backed view cannot acquire a height by accident,
        // since nothing but this one explicit constraint can influence it.
        let headerSeparator = HairlineView()
        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // Value editor: text view + the app's line-number gutter, laid out by
        // frames inside `editorContainer` exactly as QueryEditorVC does it.
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        valueTextView.string = variable.value
        valueTextView.isVerticallyResizable = true
        valueTextView.isHorizontallyResizable = true
        valueTextView.autoresizingMask = []
        valueTextView.minSize = NSSize(width: 0, height: 0)
        valueTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No wrapping: a long single-line value scrolls sideways instead of
        // reflowing, so an ID list stays one entry per line.
        valueTextView.textContainer?.widthTracksTextView = false
        valueTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        valueTextView.delegate = self
        valueTextView.onBacktab = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.nameField)
        }
        valueTextView.onCancel = { [weak self] in self?.onBack?() }
        scrollView.documentView = valueTextView

        nameField.nextKeyView = valueTextView

        let gutterView = LineNumberGutter(textView: valueTextView, scrollView: scrollView)
        gutterView.onWidthChange = { [weak self] in self?.view.needsLayout = true }
        gutter = gutterView

        editorContainer.wantsLayer = true
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(gutterView)
        editorContainer.addSubview(scrollView)

        captionLabel.font = .systemFont(ofSize: 9)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)

        duplicationLabel.font = .systemFont(ofSize: 9)
        duplicationLabel.textColor = .secondaryLabelColor
        duplicationLabel.lineBreakMode = .byWordWrapping
        duplicationLabel.maximumNumberOfLines = 2
        duplicationLabel.isHidden = true

        // A vertical stack rather than pinned constraints, because the
        // duplication note is usually absent and a stack collapses hidden
        // arranged subviews instead of leaving a gap where it would have been.
        // `editorContainer` hugs loosely so it absorbs the remaining height.
        let body = NSStackView(views: [duplicationLabel, editorContainer, captionLabel])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 5
        body.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        container.addSubview(header)
        container.addSubview(headerSeparator)
        container.addSubview(body)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 1 pt inset keeps the gutter and text inside the container's border.
        let bounds = editorContainer.bounds
        let gutterWidth = gutter?.desiredWidth ?? 0
        let height = max(0, bounds.height - 2)
        gutter?.frame = NSRect(x: 1, y: 1, width: gutterWidth, height: height)
        scrollView.frame = NSRect(
            x: 1 + gutterWidth, y: 1,
            width: max(0, bounds.width - gutterWidth - 2), height: height
        )
    }

    // MARK: - API

    /// Move focus to the name field — used right after `+` creates a variable.
    func focusNameField() {
        view.window?.makeFirstResponder(nameField)
    }

    /// Apply the state the panel resolved for this variable. Both signals appear
    /// here because both are consequences of the name, and the name is edited on
    /// this screen: red for a value that cannot render, and a duplication note
    /// that tells you which of two same-named rows the query actually uses.
    ///
    /// The note appears as you type, so a duplicate is caught when it is created
    /// rather than discovered later. It comes from the same `rowStates` pass the
    /// list uses, so the two levels cannot contradict each other.
    func setState(_ state: VariableSubstitutor.RowState?) {
        let problem = state?.problem
        nameField.textColor = problem == nil ? .systemIndigo : .systemRed
        nameField.toolTip = problem?.message

        switch state?.duplication {
        case .shadowed:
            duplicationLabel.stringValue = "Redefined below — this row has no effect."
            duplicationLabel.isHidden = false
        case .overriding:
            duplicationLabel.stringValue = "Also defined above — this definition wins."
            duplicationLabel.isHidden = false
        case nil:
            duplicationLabel.stringValue = ""
            duplicationLabel.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func backTapped() { onBack?() }
    @objc private func deleteTapped() { onDelete?() }

    @objc private func typeChanged() {
        let index = typePopup.indexOfSelectedItem
        guard index >= 0, index < VariableType.allCases.count else { return }
        variable.type = VariableType.allCases[index]
        onChange?(variable)
    }

    /// Escape with neither text control focused (e.g. straight after the slide).
    override func cancelOperation(_ sender: Any?) { onBack?() }
}

extension VariableDetailVC: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        variable.name = nameField.stringValue
        onChange?(variable)
    }

    /// Escape while the name field has focus returns to the list.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onBack?()
        return true
    }
}

extension VariableDetailVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        variable.value = valueTextView.string
        captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)
        onChange?(variable)
    }
}

/// Field-style rounded background for the value editor. Uses `updateLayer` (not
/// a one-shot `layer.backgroundColor = ....cgColor`) so the semantic colors are
/// re-resolved when the effective appearance changes.
private final class EditorBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A 1pt hairline that tracks light/dark via `updateLayer`, matching
/// `VariableListView`'s private `HairlineView` (duplicated rather than shared
/// since that one is private to its own file). See the comment at
/// `headerSeparator`'s construction above for why this replaces `NSBox`.
private final class HairlineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
