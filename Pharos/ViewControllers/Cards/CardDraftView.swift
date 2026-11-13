import AppKit

/// "Describe the query", inside a card: the strip between the name row and
/// the SQL where the analyst writes a sentence and reads the draft that comes
/// back.
///
/// It shows a `CardDraftSession` and owns none of it. The words, the draft
/// and the task that asks the model live in the session, so the strip can be
/// hidden, scrolled away or dropped with its tab while the draft goes on.
/// Nothing here closes it but its own Hide and Close buttons: a click
/// elsewhere, or another window taking the keyboard, leaves it as it is.
final class CardDraftView: NSView, NSTextFieldDelegate {
    static let inset = NSEdgeInsets(top: 8, left: 10, bottom: 9, right: 10)
    /// Two lines of description, and at most five before the field scrolls.
    static let fieldHeights: ClosedRange<CGFloat> = 40...92

    /// The field's text changed (every keystroke).
    var onRequestChanged: ((String) -> Void)?
    var onDraft: (() -> Void)?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onInsert: (() -> Void)?
    /// Hide the strip; the draft goes on.
    var onMinimize: (() -> Void)?
    /// Close the strip and drop its draft.
    var onClose: (() -> Void)?
    /// The strip needs a different height (the field grew a line).
    var onHeightChange: (() -> Void)?
    /// Colour `sql` into the preview at the editor's font and theme. Unset,
    /// the preview uses the system's monospaced font.
    var configurePreview: ((CardPreviewView, String) -> Void)?

    let field = NSTextField()
    let preview = CardPreviewView()
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let progressLabel = NSTextField(labelWithString: "")
    let draftButton = NSButton()
    let stopButton = NSButton()
    let retryButton = NSButton()
    let insertButton = NSButton()
    let hideButton = NSButton()
    let closeButton = NSButton()

    private let titleLabel = NSTextField(labelWithString: String(localized: "What should the query return?"))
    private let spinner = NSProgressIndicator()
    private let progressRow = NSStackView()
    private let previewBox = DraftPreviewBox()
    private let attributionSlot = NSStackView()
    private let buttonRow = NSStackView()
    private let stack = NSStackView()
    private var fieldHeight: NSLayoutConstraint!
    private var previewHeight: NSLayoutConstraint!

    private var phase: CardDraftSession.Phase = .editing
    private var unavailableReason: String?
    private var shownSQL: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, image, label, help, action): (NSButton, String, String, String, Selector) in [
            (hideButton, "chevron.up", String(localized: "Hide Description"),
             String(localized: "Hide the description. A draft in progress keeps running; the card's Describe button shows it again."),
             #selector(minimizePressed)),
            (closeButton, "xmark", String(localized: "Close Description"),
             String(localized: "Close the description and discard its draft"), #selector(closePressed)),
        ] {
            button.image = symbol(image, label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = help
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        let titleRow = NSStackView(views: [titleLabel, NSView(), hideButton, closeButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8

        // Multi-line: a description is a sentence, sometimes two. Return
        // sends it; Option-Return starts a new line.
        field.placeholderString = String(localized: "Orders per region this year")
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "What should the query return?"))
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Self.fieldHeights.lowerBound)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressRow.setViews([spinner, progressLabel], in: .leading)
        progressRow.orientation = .horizontal
        progressRow.spacing = 6

        // The draft, read-only: it reaches the card's SQL only by Insert.
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(preview)
        previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 0)
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.staticText)
        preview.setAccessibilityLabel(String(localized: "Draft"))

        attributionSlot.orientation = .vertical

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isSelectable = true

        for (button, title, action): (NSButton, String, Selector) in [
            (draftButton, String(localized: "Draft"), #selector(draftPressed)),
            (stopButton, String(localized: "Stop"), #selector(stopPressed)),
            (retryButton, String(localized: "Retry"), #selector(retryPressed)),
            (insertButton, String(localized: "Insert"), #selector(insertPressed)),
        ] {
            button.title = title
            button.bezelStyle = .push
            button.controlSize = .regular
            button.target = self
            button.action = action
        }
        draftButton.toolTip = String(localized: "Draft the query (\u{21A9})")
        stopButton.toolTip = String(localized: "Stop this draft. The description stays.")
        retryButton.toolTip = String(localized: "Ask the same question again")
        buttonRow.setViews([NSView(), stopButton, retryButton, insertButton, draftButton], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        stack.setViews([titleRow, field, progressRow, previewBox, attributionSlot, noteLabel, buttonRow], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 999, not required: the card gives the strip its frame by hand, and
        // for one pass that frame can be the old height.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset.bottom)
        bottom.priority = NSLayoutConstraint.Priority(999)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.right)
        trailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.left),
            trailing,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset.top),
            bottom,
            fieldHeight,
            previewHeight,
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 1),
            preview.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -1),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 1),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -1),
        ])
        // The rows that span the strip. `NSStackView.alignment` has no
        // `.fill`, and `.width` is silently refused: pin instead.
        for row in [titleRow, field, previewBox, attributionSlot, noteLabel, buttonRow] as [NSView] {
            let width = row.widthAnchor.constraint(equalTo: stack.widthAnchor)
            width.priority = NSLayoutConstraint.Priority(999)
            width.isActive = true
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Describe the query"))
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        // A shade under the card's own ground, so the strip reads as a tool
        // on the card and not as part of its SQL. Drawn, not set on a layer:
        // a layer colour freezes at the appearance it was resolved in.
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// The height the strip needs at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        let content = max(40, width - Self.inset.left - Self.inset.right)
        noteLabel.preferredMaxLayoutWidth = content
        fieldHeight.constant = fieldHeight(forWidth: content)
        if !previewBox.isHidden { previewHeight.constant = preview.height(forWidth: content - 2) + 2 }
        return ceil(stack.fittingSize.height + Self.inset.top + Self.inset.bottom)
    }

    private func fieldHeight(forWidth width: CGFloat) -> CGFloat {
        guard let cell = field.cell else { return Self.fieldHeights.lowerBound }
        // The field editor holds the text while the analyst types.
        let text = field.currentEditor()?.string ?? field.stringValue
        let measured = text.isEmpty ? 0 : (text as NSString).boundingRect(
            with: NSSize(width: max(10, width - 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: cell.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).height
        return min(Self.fieldHeights.upperBound, max(Self.fieldHeights.lowerBound, ceil(measured) + 8))
    }

    // MARK: - Showing a session

    /// Show the session's state.
    /// - Parameters:
    ///   - insertTitle: "Insert", or "Replace SQL" for a card that has text.
    ///   - unavailableReason: why no draft can start now (no connected
    ///     database), or nil.
    func show(request: String, phase: CardDraftSession.Phase, insertTitle: String, unavailableReason: String?) {
        // Never under the analyst's hands: the field already has what they
        // typed, and writing it back would move the caret.
        if field.currentEditor() == nil, field.stringValue != request { field.stringValue = request }
        self.phase = phase
        self.unavailableReason = unavailableReason
        insertButton.title = insertTitle
        refresh()
    }

    /// A view that says the draft was generated, above its note; nil for none.
    func setAttribution(_ view: NSView?) {
        guard attributionSlot.arrangedSubviews.first !== view else { return }
        for old in attributionSlot.arrangedSubviews { old.removeFromSuperview() }
        if let view {
            attributionSlot.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: attributionSlot.widthAnchor).isActive = true
        }
        refresh()
    }

    private var request: String {
        (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A draft can start: there is something to ask and a database to ask
    /// about, and no answer on screen for the same words.
    var canDraft: Bool { phase == .editing && unavailableReason == nil && !request.isEmpty }

    private func refresh() {
        var note: (text: String, caution: Bool)?
        var sql: String?
        var progress: String?
        switch phase {
        case .editing:
            if let unavailableReason { note = (unavailableReason, false) }
        case .waiting:
            progress = String(localized: "Waiting for another card\u{2019}s draft\u{2026}")
        case let .drafting(step):
            progress = step.isEmpty ? String(localized: "Drafting\u{2026}") : step
        case let .ready(draft):
            sql = draft.sql
            note = (draft.note, draft.noteIsCaution)
        case let .failed(message):
            note = (message, true)
        }

        let working = phase.isWorking
        field.isEnabled = !working
        progressRow.isHidden = progress == nil
        progressLabel.stringValue = progress ?? ""
        if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        previewBox.isHidden = sql == nil
        if let sql, sql != shownSQL {
            if let configurePreview {
                configurePreview(preview, sql)
            } else {
                preview.show(sql: sql, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                             theme: .default, wraps: true, showsLineNumbers: false, variableNames: [])
            }
            preview.setAccessibilityValue(sql)
        }
        shownSQL = sql
        attributionSlot.isHidden = sql == nil || attributionSlot.arrangedSubviews.isEmpty

        noteLabel.isHidden = note == nil
        noteLabel.stringValue = note?.text ?? ""
        noteLabel.textColor = note?.caution == true ? .systemOrange : .secondaryLabelColor

        stopButton.isHidden = !working
        let answered: Bool
        switch phase {
        case .ready, .failed: answered = true
        case .editing, .waiting, .drafting: answered = false
        }
        retryButton.isHidden = !answered
        insertButton.isHidden = sql == nil
        draftButton.isHidden = phase != .editing
        draftButton.isEnabled = canDraft
        needsLayout = true
    }

    /// Put the keyboard in the description field.
    func focusField() {
        guard field.isEnabled else { return }
        window?.makeFirstResponder(field)
    }

    /// The keyboard is in the description field.
    var fieldHasFocus: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Accessibility identifiers for card `n` (1-based): `editor.card.n.draft…`.
    func setIdentifiers(prefix: String) {
        setAccessibilityIdentifier("\(prefix).draft")
        field.setAccessibilityIdentifier("\(prefix).draft.field")
        preview.setAccessibilityIdentifier("\(prefix).draft.sql")
        noteLabel.setAccessibilityIdentifier("\(prefix).draft.note")
        progressLabel.setAccessibilityIdentifier("\(prefix).draft.progress")
        draftButton.setAccessibilityIdentifier("\(prefix).draft.draft")
        stopButton.setAccessibilityIdentifier("\(prefix).draft.stop")
        retryButton.setAccessibilityIdentifier("\(prefix).draft.retry")
        insertButton.setAccessibilityIdentifier("\(prefix).draft.insert")
        hideButton.setAccessibilityIdentifier("\(prefix).draft.hide")
        closeButton.setAccessibilityIdentifier("\(prefix).draft.close")
    }

    // MARK: - Actions

    @objc private func draftPressed() { if canDraft { onDraft?() } }
    @objc private func stopPressed() { onStop?() }
    @objc private func retryPressed() { onRetry?() }
    @objc private func insertPressed() { onInsert?() }
    @objc private func minimizePressed() { onMinimize?() }
    @objc private func closePressed() { onClose?() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onRequestChanged?(field.currentEditor()?.string ?? field.stringValue)
        draftButton.isEnabled = canDraft
        // Only when the text reaches another line: a relayout moves every
        // card below this one.
        if abs(fieldHeight(forWidth: stack.bounds.width) - fieldHeight.constant) > 0.5 { onHeightChange?() }
    }

    /// Return drafts, Option-Return starts a new line (the field editor's
    /// own), Escape hides the strip without stopping anything.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if canDraft { onDraft?() } else if phase == .editing { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onMinimize?()
            return true
        default:
            return false
        }
    }

    /// ⌘↩ in the description drafts too. It is taken here, before the menu
    /// sees it, or Query ▸ Run would run the card the analyst is describing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if fieldHasFocus, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            if canDraft { onDraft?() } else { NSSound.beep() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The ground and outline of the draft's preview: the editor's own ground,
/// so the draft looks like the SQL it will become. Drawn, not set on a
/// layer: a layer colour freezes at the appearance it was resolved in.
private final class DraftPreviewBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
