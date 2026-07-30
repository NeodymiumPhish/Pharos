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

    /// Builds its own TextKit stack. `init(frame:textContainer:)` with a nil
    /// container does not — it leaves `textStorage`, `layoutManager` and
    /// `textContainer` all nil, and the view then silently discards every
    /// assignment to `string`. Sizing (`isVerticallyResizable`, `minSize`,
    /// `maxSize`) stays with the host, matching `QueryEditorVC`.
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    /// A value may be SQL, an ID list, or a path — never prose. Every automatic
    /// substitution is off so nothing silently rewrites what was typed or pasted
    /// (a smart quote in a SQL fragment is a broken query, and smart insert-delete
    /// silently adding/removing spaces around a paste or deletion is exactly the
    /// kind of rewrite this view exists to avoid — relevant here in particular
    /// because a common value shape is a comma-joined ID list).
    private func applyDefaults() {
        isEditable = true
        isSelectable = true
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
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
