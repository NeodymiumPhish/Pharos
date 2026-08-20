import AppKit

extension NSTextField {

    /// Rewrite this field's live text to `TagNameSanitizer.sanitized`, keeping
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
    func sanitizeAsTagName() {
        guard let editor = currentEditor() else {
            let plain = stringValue
            guard TagNameSanitizer.needsSanitizing(plain) else { return }
            stringValue = TagNameSanitizer.sanitized(plain)
            return
        }
        // An active IME composition is never rewritten: replacing
        // editor.string unmarks and destroys the marked text mid-composition.
        // Committing the composition fires its own change notification, and
        // the rewrite runs then, so nothing deceptive survives to the store.
        if let textView = editor as? NSTextView, textView.hasMarkedText() { return }
        let raw = editor.string
        guard TagNameSanitizer.needsSanitizing(raw) else { return }
        // Both ends of the selection are mapped, not just its start: a paste
        // collapses the selection, but a rewrite can also land while text is
        // selected, and a selection whose length was left alone would extend
        // past characters the rewrite removed.
        let selection = editor.selectedRange
        let start = TagNameSanitizer.sanitizedCaret(in: raw, at: selection.location)
        let end = TagNameSanitizer.sanitizedCaret(
            in: raw, at: selection.location + selection.length)
        editor.string = TagNameSanitizer.sanitized(raw)
        editor.selectedRange = NSRange(location: start, length: end - start)
    }
}
