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

    /// Escape pressed — the host settles the edit.
    var onCancel: (() -> Void)?

    /// Rewrites pasted or dropped text before it goes in: the pasted text and
    /// the range it replaces in, the text to insert out. Nil, or a nil
    /// result, inserts the pasted text unchanged. The List editor turns a CSV
    /// row or a spreadsheet column into one item per line here
    /// (`VariableListPaste`).
    var pasteTransform: ((_ pasted: String, _ range: NSRange) -> String?)?

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
    /// `maxSize`) stays with the host, matching `SQLEditorController`.
    convenience init() {
        let storage = NSTextStorage()
        // The disclosing layout manager, not a stock one: a value is data that
        // will be substituted into SQL, so a bidi override pasted here must be
        // visible rather than obeyed. Folding is unused at this size — the fold
        // state stays empty — and the same class carries both behaviours.
        let layoutManager = FoldingLayoutManager(foldState: FoldState())
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
        writingToolsBehavior = .none
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

    /// Paste (`paste(_:)` reads the general pasteboard through here) and a
    /// drop both arrive here, so `pasteTransform` sees both. The rewrite goes
    /// through `shouldChangeText` / `didChangeText`, so it is one undo step
    /// and the delegate hears it like typing.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = selectedRange()
        guard let transform = pasteTransform, let pasted = pboard.string(forType: .string),
              let replacement = transform(pasted, range) else {
            return super.readSelection(from: pboard, type: type)
        }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        // With the typing attributes: a bare string would take the font of
        // the character before it, and an empty view has none.
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement,
                                                                            attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        return true
    }
}
