import AppKit

/// NSRulerView that displays line numbers for an NSTextView.
class LineNumberGutter: NSRulerView {

    private let textView: NSTextView
    private var lineAttributes: [NSAttributedString.Key: Any] = [:]
    private var errorLines: Set<Int> = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)

        clientView = textView
        ruleThickness = 40

        lineAttributes = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Observe text changes and scroll
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Error Markers

    func setErrorLines(_ lines: Set<Int>) {
        errorLines = lines
        needsDisplay = true
    }

    func clearErrors() {
        errorLines.removeAll()
        needsDisplay = true
    }

    // MARK: - Notifications

    @objc private func textDidChange(_ notification: Notification) {
        updateThickness()
        needsDisplay = true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    // MARK: - Thickness

    private func updateThickness() {
        let lineCount = max(textView.string.components(separatedBy: "\n").count, 1)
        let digits = max(String(lineCount).count, 3)
        let digitWidth = NSAttributedString(string: "8", attributes: lineAttributes).size().width
        let newThickness = CGFloat(digits) * digitWidth + 20
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let textInset = textView.textContainerInset

        // Background
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        rect.fill()

        // Right border
        NSColor.separatorColor.setStroke()
        let borderX = bounds.maxX - 0.5
        NSBezierPath.strokeLine(from: NSPoint(x: borderX, y: rect.minY), to: NSPoint(x: borderX, y: rect.maxY))

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        // Count lines before visible range
        text.enumerateSubstrings(in: NSRange(location: 0, length: visibleCharRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw line numbers for visible lines
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            lineRect.origin.y += textInset.height - visibleRect.origin.y

            // Draw error indicator
            if errorLines.contains(lineNumber) {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: 3,
                    y: lineRect.midY - dotSize / 2 + convert(.zero, from: scrollView).y,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            // Draw line number
            let numberString = "\(lineNumber)"
            let attrString = NSAttributedString(string: numberString, attributes: lineAttributes)
            let stringSize = attrString.size()
            let drawPoint = NSPoint(
                x: ruleThickness - stringSize.width - 8,
                y: lineRect.midY - stringSize.height / 2 + convert(.zero, from: scrollView).y
            )
            attrString.draw(at: drawPoint)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}
