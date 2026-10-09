import AppKit

/// A card's notes: plain text beside the SQL, on the card's right side. The
/// card stack sizes it (`width(forBody:)`) and makes the card tall enough for
/// the notes and the SQL, so the view never scrolls on its own; a wheel or
/// trackpad movement over it scrolls the stack.
final class CardNotesView: NSView, NSTextViewDelegate {
    /// The part of the card's body width the notes take until the user drags
    /// the divider.
    static let defaultFraction: CGFloat = 0.37
    /// The narrowest the notes and the SQL can be dragged. On a card too
    /// narrow for both, each gets half.
    static let minWidth: CGFloat = 180
    static let minSQLWidth: CGFloat = 240
    /// Three lines of notes, so an empty notes area is still a place to type.
    static let minHeight: CGFloat = 64
    static let textInset = NSSize(width: 10, height: 8)

    /// The notes width for a card body `bodyWidth` wide, at `fraction` of it
    /// (nil: the default), kept inside the limits.
    static func width(forBody bodyWidth: CGFloat, fraction: CGFloat? = nil) -> CGFloat {
        let lower = min(minWidth, bodyWidth / 2)
        let upper = max(bodyWidth - minSQLWidth, bodyWidth / 2)
        return min(max(bodyWidth * (fraction ?? defaultFraction), lower), upper).rounded()
    }

    /// The text changed by typing (not by `setText`).
    var onChange: ((String) -> Void)?
    /// The text view lost focus.
    var onEndEditing: (() -> Void)?

    /// TextKit 1, as the SQL editor: `height(forWidth:)` measures with the
    /// layout manager, and asking a TextKit 2 view for one switches it over.
    let textView = CardNotesTextView(usingTextLayoutManager: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // The notes go into `.sql` files as a comment: keep the characters
        // the user typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Notes"))
        addSubview(textView)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    var text: String { textView.string }

    /// Show `text`, unless the user is typing here: the model then already
    /// holds what the view shows, and a reset would move the caret. `force`
    /// is for a change that did not come from this view (comments imported
    /// into the notes): a focused view must show it too, or the next
    /// keystroke would write the old text back over it.
    func setText(_ text: String, force: Bool = false) {
        guard textView.string != text, force || window?.firstResponder !== textView else { return }
        textView.string = text
        textView.needsDisplay = true
    }

    /// The height the notes need at `width`, text insets included.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return Self.minHeight }
        let textWidth = max(0, width - 1 - Self.textInset.width * 2)
        if abs(container.size.width - textWidth) > 0.5 {
            container.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return max(Self.minHeight, ceil(used + Self.textInset.height * 2))
    }

    override func layout() {
        super.layout()
        // 1 pt at the leading edge is the separator from the SQL.
        textView.frame = NSRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onChange?(textView.string)
    }

    func textDidEndEditing(_ notification: Notification) {
        onEndEditing?()
    }
}

/// The notes text view: draws a placeholder while empty, and sends vertical
/// scrolling to the card stack.
final class CardNotesTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        NSAttributedString(string: String(localized: "Notes"), attributes: [
            .font: font ?? .systemFont(ofSize: 12),
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder comes and goes with the first character.
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // The card is as tall as its notes, so there is nothing to scroll
        // here: the stack scrolls.
        nextResponder?.scrollWheel(with: event)
    }
}

/// The handle on the line between a card's SQL and its notes: drag it to
/// make the notes wider or narrower, double-click it for the default width.
/// Wider than the 1 pt line it sits on, so it is easy to grab; it draws
/// nothing (the notes draw the line).
final class CardNotesDivider: NSView {
    static let hitWidth: CGFloat = 8

    /// The pointer moved to `x`, in the card's coordinates.
    var onDrag: ((_ x: CGFloat) -> Void)?
    /// The drag ended.
    var onDragEnd: (() -> Void)?
    /// A double-click: back to the default width.
    var onReset: (() -> Void)?
    /// VoiceOver's increment and decrement: widen (+1) or narrow (-1) the notes.
    var onStep: ((_ direction: Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Added once, following the view: AppKit does not call
        // `updateTrackingAreas` for a view it has just added.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Notes width"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        // Track the drag here, as NSSplitView does, until the button comes up.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if let card = superview {
                onDrag?(card.convert(next.locationInWindow, from: nil).x)
            }
            if next.type == .leftMouseUp { break }
        }
        onDragEnd?()
    }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(-1) // the divider moves right: the notes narrow
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(1)
        return true
    }
}
