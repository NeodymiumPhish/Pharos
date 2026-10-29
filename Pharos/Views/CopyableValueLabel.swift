import AppKit

/// A value in the Inspector's row detail. Double-click copies the whole RAW
/// value; a drag selects characters, for a part of it.
final class CopyableValueLabel: NSTextField {
    /// The RAW value, for the pasteboard. Deliberately not the same string as
    /// `stringValue`, which its setter escapes for display: an analyst pastes
    /// indicators out of this pane into other systems, so the copy must be the
    /// bytes the database returned, not the `<U+XXXX>` rendering of them.
    /// The one place it is READ for display — the context-menu title — escapes
    /// it at that point instead.
    var copyableValue: String = ""
    private var savedAttributedString: NSAttributedString?
    private var restoreTimer: Timer?

    override func layout() {
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
        }
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            copyToPasteboard()
            showCopiedFeedback()
        } else {
            super.mouseDown(with: event)
        }
    }

    // The label is selectable, so after the first click the window's field
    // editor sits on top of it and takes the clicks: a drag selects characters
    // and ⌘C copies them as SHOWN. A double-click must still copy the whole
    // raw value, and the editor's context menu must still offer it.

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Not the delegate method: NSTextField implements that one itself, and
        // the editor never asks a subclass's version.
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func editorSelectionDidChange(_ note: Notification) {
        guard let editor = currentEditor(), note.object as AnyObject === editor,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown, event.clickCount == 2 else { return }
        // Inside the editor's mouse tracking: end the editing after it returns.
        DispatchQueue.main.async { [weak self] in
            self?.copyToPasteboard()
            self?.showCopiedFeedback()
        }
    }

    // The field editor's delegate is this label.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        menu.insertItem(copyValueItem(), at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(copyValueItem())
        return menu
    }

    private func copyValueItem() -> NSMenuItem {
        // Truncate the RAW value first, then escape — escaping first and cutting
        // at 50 would slice a `<U+202E>` token in half and print the debris.
        // The menu title is display, so it is escaped; `copyValue` still puts
        // the raw `copyableValue` on the pasteboard.
        let clipped = copyableValue.count > 50
            ? String(copyableValue.prefix(50)) + "\u{2026}"
            : copyableValue
        let display = DisplayEscape.escaped(clipped)
        let item = NSMenuItem(title: "Copy \"\(display)\"", action: #selector(copyValue), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyValue() {
        copyToPasteboard()
        showCopiedFeedback()
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableValue, forType: .string)
    }

    private func showCopiedFeedback() {
        // The field editor draws over the label while a selection is live, so
        // the feedback would not show until the editing ends.
        abortEditing()
        restoreTimer?.invalidate()
        // A second copy inside the 0.8 s would otherwise save "✓ Copied" as the
        // value to restore.
        if savedAttributedString == nil {
            savedAttributedString = attributedStringValue
        }

        let feedback = NSMutableAttributedString(
            string: "\u{2713} Copied",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.systemGreen,
            ]
        )
        attributedStringValue = feedback

        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self, let saved = self.savedAttributedString else { return }
            self.attributedStringValue = saved
            self.savedAttributedString = nil
        }
    }
}
