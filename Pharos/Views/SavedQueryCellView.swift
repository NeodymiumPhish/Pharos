import AppKit

// MARK: - Compact Cell View

class SavedQueryCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private weak var editingDelegate: SavedQueryCellEditingDelegate?

    /// The name as the STORE holds it, kept because neither of the two things
    /// this cell draws can be derived from the other.
    ///
    /// `titleLabel` is both the label and the inline rename field, and those
    /// two jobs want opposite halves of the same defence. Deriving the field
    /// from the label would seed the rename with the disclosure token — the
    /// user would then save the literal text `<U+202E>` as the name. Deriving
    /// the label from the field would draw a hostile name as though it were
    /// clean. So both are derived from this.
    private var rawTitle = ""

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage?, tint: NSColor, title: String, isHighlighted: Bool = false) {
        iconView.image = icon
        iconView.contentTintColor = tint
        rawTitle = title
        titleLabel.stringValue = displayTitle
        titleLabel.font = isHighlighted ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
    }

    /// The row as it is READ: escaped, so a bidi override cannot reorder the
    /// row and make one saved query read as another, and trimmed, because both
    /// save paths commit the name trimmed and one name must not read two ways
    /// in one window.
    private var displayTitle: String { DisplayEscape.escapedTrimmed(rawTitle) }

    /// Makes the title label editable and selects all text for immediate renaming.
    func beginEditing(delegate: SavedQueryCellEditingDelegate) {
        editingDelegate = delegate

        // The field is seeded from the RAW name, SANITISED — never from the
        // escaped label. Whatever the field holds is what the user goes on to
        // save, so the deceptive scalar is DENIED ENTRY here rather than
        // disclosed: disclosing it would offer the token's own text as the new
        // name. Seeded before the field becomes first responder, so the field
        // editor is built from this string and not from the label.
        //
        // `sanitized`, not `committed`: it does not trim. An edge space is the
        // author's own text and stays visible to keep or to remove, matching
        // the rename sheet and the connections manager. The save trims either
        // way.
        titleLabel.stringValue = AuthoredLabelSanitizer.sanitized(rawTitle)

        titleLabel.isEditable = true
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.delegate = self

        // `selectText` alone. It already makes the field editor the first
        // responder, so the `makeFirstResponder` that used to follow it ENDED
        // the editing session `selectText` had just started and began a second
        // one — an end-of-editing callback arriving in the middle of
        // `beginEditing`, which is exactly the callback the restoration below
        // listens for.
        titleLabel.selectText(nil)
    }

    fileprivate func endEditing() {
        // Idempotent: editing can end down two paths — the commit below and
        // AppKit's own end-of-editing callback — and the app takes the first,
        // headless tests take the second.
        guard titleLabel.isEditable else { return }
        titleLabel.isEditable = false
        titleLabel.delegate = nil
        editingDelegate = nil

        // Back to the DISCLOSING form. Not cosmetic: a rename the cell refuses
        // — the name was emptied — calls no delegate, so nothing reloads the
        // row, and the sanitised text would otherwise stay on screen as a
        // hostile name drawn clean. A rename that DOES commit is redrawn by the
        // reload a moment later, so this restores the old name only briefly.
        titleLabel.stringValue = displayTitle
    }
}

protocol SavedQueryCellEditingDelegate: AnyObject {
    func cellView(_ cellView: SavedQueryCellView, didFinishEditingWithText text: String)
}

extension SavedQueryCellView: NSTextFieldDelegate {
    /// The inline folder rename is an authored label, sanitised as it is typed.
    /// `textShouldEndEditing` below reads the FIELD EDITOR, so a rewrite here is
    /// exactly what that method goes on to see.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleLabel else { return }
        titleLabel.sanitizeAsAuthoredLabel()
    }

    /// Editing ended without going through the commit below — the field editor
    /// resigned rather than the rename being confirmed. Nothing reloads the row
    /// in that case, so the row would keep the SANITISED text on screen: a
    /// hostile name drawn clean, which is the whole defect. `endEditing`
    /// restores the disclosing label.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleLabel else { return }
        endEditing()
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        let newName = AuthoredLabelSanitizer.committed(fieldEditor.string)
        let delegate = editingDelegate

        // The restoration goes through the FIELD EDITOR, not only through the
        // field. AppKit copies the editor into the field AFTER this method
        // returns true, so a label restored here and nowhere else is overwritten
        // a moment later by the very text the user was editing — and for a
        // refused rename that text is the sanitised hostile name, drawn clean.
        // `endEditing` restores the field as well, for the case where the
        // editor is already gone.
        fieldEditor.string = displayTitle
        endEditing()
        if !newName.isEmpty {
            delegate?.cellView(self, didFinishEditingWithText: newName)
        }
        return true
    }
}
