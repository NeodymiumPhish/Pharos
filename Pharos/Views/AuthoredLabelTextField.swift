import AppKit

/// A text field for an AUTHORED LABEL — a name the analyst types for their own
/// object: a folder, a workspace, a saved query, a connection, a tab.
///
/// It is its own delegate, and sanitises itself on every change, so a caller
/// only has to choose this type instead of `NSTextField`. That matters most
/// where the field is a local inside an `NSAlert` accessory view: those have no
/// delegate at all, and giving one to each presenting view controller would
/// mean four new `NSTextFieldDelegate` conformances, four identity checks, and
/// four chances to forget.
///
/// Measured: the change notification arrives for typing and for paste, the
/// field-editor rewrite lands with the caret preserved, and it terminates
/// because sanitised text is a fixed point — a rewrite cannot re-trigger a
/// rewrite.
///
/// If a caller needs its own delegate on the same field, do NOT use this type —
/// reassigning `delegate` silently disables the sanitising. Use a plain
/// `NSTextField` and call `sanitizeAsAuthoredLabel()` from that delegate
/// instead, as `VariableDetailVC` and `ConnectionsManagerVC` do.
final class AuthoredLabelTextField: NSTextField, NSTextFieldDelegate {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func controlTextDidChange(_ obj: Notification) {
        sanitizeAsAuthoredLabel()
    }
}
