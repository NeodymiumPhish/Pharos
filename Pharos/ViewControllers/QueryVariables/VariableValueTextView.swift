import AppKit

/// The multi-line value editor for a query variable.
///
/// Replaces the panel's original `NSTextField`, which as a field editor routed
/// Tab to "move focus" and Return to "commit" — so typed tabs and newlines never
/// reached the text storage while pasted ones did. A text view accepts both as
/// characters. Tab insertion is overridden explicitly rather than leaning on the
/// inherited default, and Shift-Tab and Escape are handed to the host so the
/// editor is not a focus dead end.
final class VariableValueTextView: NSTextView {

    /// Shift-Tab pressed — the host moves focus back to the name field.
    var onBacktab: (() -> Void)?

    /// Escape pressed — the host returns to the list level.
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        applyDefaults()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// A value may be SQL, an ID list, or a path — never prose. Every automatic
    /// substitution is off so nothing silently rewrites what was typed or pasted
    /// (a smart quote in a SQL fragment is a broken query).
    private func applyDefaults() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        allowsUndo = true
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textColor = .labelColor
        drawsBackground = false
        textContainerInset = NSSize(width: 2, height: 4)
    }

    override func insertTab(_ sender: Any?) {
        insertText("\t", replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        onBacktab?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
