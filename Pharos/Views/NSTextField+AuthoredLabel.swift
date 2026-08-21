import AppKit

extension NSTextField {

    /// Rewrite this field's live text to `AuthoredLabelSanitizer.sanitized`, keeping
    /// the insertion point where the reader put it.
    ///
    /// Called from `controlTextDidChange`, so the field never HOLDS a
    /// deceptive name: what the analyst reads before pressing Create or Save
    /// is exactly what the store receives. Sanitising only at save would mean
    /// storing something other than what the field displayed, which is its own
    /// kind of lie.
    ///
    /// The field editor, not `stringValue`, is what gets rewritten while an
    /// edit is in progress: assigning `stringValue` mid-edit ends up with the
    /// insertion point at the end of the text, which would throw the caret to
    /// the end of the name on every paste into the middle of one. The
    /// `stringValue` path is for a call made outside an edit session, where
    /// there is no field editor to ask.
    ///
    /// `needsSanitizing` first, so ordinary typing never touches the editor at
    /// all — and so this is safe to call from the change notification that
    /// rewriting the editor may itself raise: the sanitised text is a fixed
    /// point, so a second pass changes nothing and stops.
    ///
    /// An editor holding marked text (an IME composition in progress) is left
    /// alone entirely; the rewrite runs when the composition commits instead.
    func sanitizeAsAuthoredLabel() {
        guard let editor = currentEditor() else {
            let plain = stringValue
            guard AuthoredLabelSanitizer.needsSanitizing(plain) else { return }
            stringValue = AuthoredLabelSanitizer.sanitized(plain)
            return
        }
        // An active IME composition is never rewritten: replacing
        // editor.string unmarks and destroys the marked text mid-composition.
        // Committing the composition fires its own change notification, and
        // the rewrite runs then, so nothing deceptive survives to the store.
        if let textView = editor as? NSTextView, textView.hasMarkedText() { return }
        let raw = editor.string
        guard AuthoredLabelSanitizer.needsSanitizing(raw) else { return }
        // Both ends of the selection are mapped, not just its start: a paste
        // collapses the selection, but a rewrite can also land while text is
        // selected, and a selection whose length was left alone would extend
        // past characters the rewrite removed.
        let selection = editor.selectedRange
        let start = AuthoredLabelSanitizer.sanitizedCaret(in: raw, at: selection.location)
        let end = AuthoredLabelSanitizer.sanitizedCaret(
            in: raw, at: selection.location + selection.length)
        let sanitised = AuthoredLabelSanitizer.sanitized(raw)
        editor.string = sanitised
        editor.selectedRange = NSRange(location: start, length: end - start)
        announceSanitising(raw: raw, sanitised: sanitised)
    }

    /// Say what was just taken out, and show the original with its invisible
    /// characters made visible.
    ///
    /// Only on the EDITOR path, never on the `stringValue` path above: that one
    /// is the seed, and a notice every time a sheet opens on a stored name
    /// would be noise rather than news. This fires when the text the analyst
    /// just typed or pasted was rewritten under them, which is the moment the
    /// silence was surprising.
    ///
    /// Fires once per rewrite, not per keystroke: sanitised text is a fixed
    /// point, so the `needsSanitizing` guard above stops the very next change
    /// from reaching here.
    private func announceSanitising(raw: String, sanitised: String) {
        guard let notice = SanitiseNotice.message(raw: raw, sanitised: sanitised),
              let host = window?.contentView
        else { return }
        // `window.contentView` rather than a superview: four of these fields
        // are the accessory view of an `NSAlert`, whose own window hosts the
        // toast perfectly well, and none of the nine sites has to lay anything
        // out for this.
        Toast.show(in: host, message: notice, style: .warning, duration: 5.0)
    }
}
