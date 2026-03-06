import AppKit

/// Standalone line number gutter drawn as a plain NSView beside the scroll view.
/// Unlike the previous NSRulerView implementation, this view lives *outside* the
/// NSScrollView hierarchy, which avoids the system-injected NSVisualEffectView
/// that macOS 26 attaches to ruler infrastructure (causing washed-out text).
class LineNumberGutter: NSView {

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var lineAttributes: [NSAttributedString.Key: Any] = [:]
    private var errorLines: Set<Int> = []

    /// Current width the gutter needs. The host VC reads this to lay out frames.
    private(set) var desiredWidth: CGFloat = 40

    /// Called when `desiredWidth` changes so the host VC can re-layout.
    var onWidthChange: (() -> Void)?

    /// The line number containing the insertion point (1-based), used to highlight the active line number.
    private var currentLine: Int = 0

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)

        lineAttributes = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // Track cursor position for current-line highlighting
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func setErrorLines(_ lines: Set<Int>) {
        errorLines = lines
        needsDisplay = true
    }

    func clearErrors() {
        errorLines.removeAll()
        needsDisplay = true
    }

    /// Force a redraw — call after programmatic text changes (e.g. setSQL).
    func invalidateLineNumbers() {
        recalculateWidth()
        needsDisplay = true
    }

    // MARK: - Notifications

    @objc private func textDidChange(_: Notification) {
        recalculateWidth()
        needsDisplay = true
    }

    @objc private func boundsDidChange(_: Notification) {
        needsDisplay = true
    }

    @objc private func selectionDidChange(_: Notification) {
        guard let textView else { return }
        let cursor = textView.selectedRange().location
        let text = textView.string
        // Count newlines before the cursor to determine the 1-based line number
        let end = text.index(text.startIndex, offsetBy: min(cursor, text.count))
        let line = text[text.startIndex..<end].reduce(1) { count, ch in
            ch == "\n" ? count + 1 : count
        }
        if currentLine != line {
            currentLine = line
            needsDisplay = true
        }
    }

    // MARK: - Width

    private func recalculateWidth() {
        guard let textView else { return }
        let lineCount = max(textView.string.components(separatedBy: "\n").count, 1)
        let digits = max(String(lineCount).count, 3)
        let digitWidth = NSAttributedString(string: "8", attributes: lineAttributes).size().width
        let newWidth = CGFloat(digits) * digitWidth + 20
        if abs(desiredWidth - newWidth) > 1 {
            desiredWidth = newWidth
            onWidthChange?()
        }
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        let scrollOffset = scrollView.contentView.bounds.origin.y
        let textInset = textView.textContainerInset

        // Background — seamless with editor (no visible boundary)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // Prepare attributes for current-line vs normal line numbers
        let normalAttributes = lineAttributes
        var activeAttributes = lineAttributes
        activeAttributes[.foregroundColor] = NSColor.labelColor

        // Visible range in the text view
        let visibleTextRect = NSRect(
            x: 0, y: scrollOffset,
            width: scrollView.contentView.bounds.width,
            height: scrollView.contentView.bounds.height
        )
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleTextRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Count lines before the visible range to get starting line number
        var lineNumber = 1
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw line numbers for visible lines
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

            // y position in our coordinate space: line's position in text + inset - scroll offset
            let y = lineRect.origin.y + textInset.height - scrollOffset

            // Error indicator dot
            if errorLines.contains(lineNumber) {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: 3,
                    y: y + (lineRect.height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            // Line number text — bright for current line, muted for others
            let numberString = "\(lineNumber)"
            let attrs = (lineNumber == currentLine) ? activeAttributes : normalAttributes
            let attrString = NSAttributedString(string: numberString, attributes: attrs)
            let stringSize = attrString.size()
            let drawPoint = NSPoint(
                x: desiredWidth - stringSize.width - 8,
                y: y + (lineRect.height - stringSize.height) / 2
            )
            attrString.draw(at: drawPoint)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}
