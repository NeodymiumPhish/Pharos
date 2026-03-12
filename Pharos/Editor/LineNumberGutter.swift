import AppKit

/// Standalone line number gutter drawn as a plain NSView beside the scroll view.
/// Unlike the previous NSRulerView implementation, this view lives *outside* the
/// NSScrollView hierarchy, which avoids the system-injected NSVisualEffectView
/// that macOS 26 attaches to ruler infrastructure (causing washed-out text).
///
/// Also draws SQL segment bars (similar to Xcode's source control change bars)
/// to visually delineate individual SQL statements, with a hoverable run button.
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

    // MARK: - Segment Bar State

    /// Parsed SQL segments for the current editor text.
    private var segments: [SQLSegment] = []

    /// Index of the segment the cursor is currently inside (nil if none).
    private var activeSegmentIndex: Int?

    /// Maps segment index → color (set when a result tab is created for that segment).
    private var segmentColors: [Int: NSColor] = [:]

    /// Index of the segment currently being hovered (nil if none).
    private var hoveredSegmentIndex: Int?

    /// Callback fired when the user clicks the run button on a segment bar.
    var onRunSegment: ((SQLSegment) -> Void)?

    // MARK: - Fold Chevron State

    /// Current fold regions for chevron display.
    private var foldRegions: [SQLFoldRegion] = []

    /// Callback when user clicks a fold chevron. Passes the region index.
    var onToggleFold: ((Int) -> Void)?

    /// Whether the mouse is currently inside the gutter (for showing expanded chevrons).
    private var mouseInGutter: Bool = false

    // Segment bar layout constants
    private let segmentBarWidth: CGFloat = 4
    private let segmentBarGap: CGFloat = 6  // gap between line numbers and bar

    private var gutterTrackingArea: NSTrackingArea?

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

    /// Update the segment data. Called by the host VC when text changes or cursor moves.
    func setSegments(_ newSegments: [SQLSegment], activeIndex: Int?) {
        segments = newSegments
        activeSegmentIndex = activeIndex
        needsDisplay = true
    }

    /// Set the color for a segment (e.g., after a result tab is created).
    func setSegmentColor(_ color: NSColor?, forSegmentIndex index: Int) {
        if let color {
            segmentColors[index] = color
        } else {
            segmentColors.removeValue(forKey: index)
        }
        needsDisplay = true
    }

    /// Clear all segment result colors.
    func clearSegmentColors() {
        segmentColors.removeAll()
        needsDisplay = true
    }

    /// Update the fold regions for chevron display.
    func setFoldRegions(_ regions: [SQLFoldRegion]) {
        foldRegions = regions
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
        let lineCount = max(textView.string.utf16.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }, 1)
        let digits = max(String(lineCount).count, 3)
        let digitWidth = NSAttributedString(string: "8", attributes: lineAttributes).size().width
        let newWidth = CGFloat(digits) * digitWidth + 20 + segmentBarWidth + segmentBarGap
        if abs(desiredWidth - newWidth) > 1 {
            desiredWidth = newWidth
            onWidthChange?()
        }
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = gutterTrackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        gutterTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInGutter = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let barColumnX = desiredWidth - segmentBarGap - segmentBarWidth

        // Track mouse-in-gutter for fold chevron visibility
        if !mouseInGutter {
            mouseInGutter = true
            needsDisplay = true
        }

        // Only respond to segment bar hovers in the segment bar column area (with some padding)
        guard point.x >= barColumnX - 4 else {
            if hoveredSegmentIndex != nil {
                hoveredSegmentIndex = nil
                needsDisplay = true
            }
            return
        }

        let lineAtPoint = lineNumber(at: point)
        let newHovered = segments.firstIndex { seg in
            lineAtPoint >= seg.startLine && lineAtPoint <= seg.endLine
        }

        if hoveredSegmentIndex != newHovered {
            hoveredSegmentIndex = newHovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        mouseInGutter = false
        if hoveredSegmentIndex != nil {
            hoveredSegmentIndex = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check fold chevron click first (leftmost 14pt column)
        if point.x < 14 {
            let lineAtPoint = lineNumber(at: point)
            if let regionIdx = foldRegions.firstIndex(where: { $0.startLine == lineAtPoint }) {
                onToggleFold?(regionIdx)
                return
            }
        }

        let barColumnX = desiredWidth - segmentBarGap - segmentBarWidth

        // Only handle clicks in the segment bar column
        guard point.x >= barColumnX - 4,
              let idx = hoveredSegmentIndex,
              idx < segments.count else {
            super.mouseDown(with: event)
            return
        }

        onRunSegment?(segments[idx])
    }

    /// Map a point (in gutter coordinates) to a 1-based line number.
    private func lineNumber(at point: NSPoint) -> Int {
        guard let textView, let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 0 }

        let scrollOffset = scrollView.contentView.bounds.origin.y
        let textInset = textView.textContainerInset

        // Convert gutter y to text view y
        let textY = point.y + scrollOffset - textInset.height

        let text = textView.string as NSString
        guard text.length > 0 else { return 1 }

        // Find the glyph at this y position
        let testPoint = NSPoint(x: 0, y: textY)
        let glyphIndex = layoutManager.glyphIndex(for: testPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        // Count newlines up to charIndex to get line number
        let end = min(charIndex, text.length)
        var line = 1
        for j in 0..<end {
            if text.character(at: j) == 0x0A { line += 1 }
        }
        return line
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

        // Build a map of line number → y position and line height for segment bar drawing
        var lineYPositions: [(line: Int, y: CGFloat, height: CGFloat)] = []

        // Draw line numbers for visible lines
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

            // y position in our coordinate space: line's position in text + inset - scroll offset
            let y = lineRect.origin.y + textInset.height - scrollOffset

            lineYPositions.append((line: lineNumber, y: y, height: lineRect.height))

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

            // Fold chevron — draw on fold region start lines
            if let regionIdx = foldRegions.firstIndex(where: { $0.startLine == lineNumber }) {
                let region = foldRegions[regionIdx]
                let showChevron = region.isCollapsed || mouseInGutter
                if showChevron {
                    drawFoldChevron(
                        collapsed: region.isCollapsed,
                        at: NSPoint(x: 3, y: y),
                        lineHeight: lineRect.height
                    )
                }
            }

            // Line number text — right-aligned before the segment bar column
            let numberString = "\(lineNumber)"
            let attrs = (lineNumber == currentLine) ? activeAttributes : normalAttributes
            let attrString = NSAttributedString(string: numberString, attributes: attrs)
            let stringSize = attrString.size()
            let drawPoint = NSPoint(
                x: desiredWidth - segmentBarWidth - segmentBarGap - stringSize.width - 4,
                y: y + (lineRect.height - stringSize.height) / 2
            )
            attrString.draw(at: drawPoint)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        // Draw segment bars
        guard !segments.isEmpty, !lineYPositions.isEmpty,
              let firstEntry = lineYPositions.first,
              let lastEntry = lineYPositions.last else { return }

        let barX = desiredWidth - segmentBarGap / 2 - segmentBarWidth
        let firstVisibleLine = firstEntry.line
        let lastVisibleLine = lastEntry.line

        // Build lookup dictionary for O(1) line → position mapping
        var linePositionMap: [Int: (y: CGFloat, height: CGFloat)] = [:]
        linePositionMap.reserveCapacity(lineYPositions.count)
        for entry in lineYPositions {
            linePositionMap[entry.line] = (entry.y, entry.height)
        }

        for (segIdx, segment) in segments.enumerated() {
            // Skip segments that don't overlap the visible line range
            guard segment.endLine >= firstVisibleLine && segment.startLine <= lastVisibleLine else { continue }

            // Find y-coordinates for the segment's visible extent
            let clampedStart = max(segment.startLine, firstVisibleLine)
            let clampedEnd = min(segment.endLine, lastVisibleLine)

            guard let startEntry = linePositionMap[clampedStart],
                  let endEntry = linePositionMap[clampedEnd] else { continue }

            let barY = startEntry.y + 2
            let barBottom = endEntry.y + endEntry.height - 2
            let barHeight = max(barBottom - barY, 4)

            // Determine bar color
            let barColor: NSColor
            if let resultColor = segmentColors[segIdx] {
                barColor = resultColor
            } else if segIdx == activeSegmentIndex {
                barColor = NSColor.controlAccentColor
            } else {
                barColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
            }

            // Draw the bar
            let barRect = NSRect(x: barX, y: barY, width: segmentBarWidth, height: barHeight)
            barColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()

            // Draw run button on hover
            if segIdx == hoveredSegmentIndex {
                drawRunButton(at: barRect, color: barColor)
            }
        }
    }

    /// Draw a fold disclosure chevron (right-pointing when collapsed, down-pointing when expanded).
    private func drawFoldChevron(collapsed: Bool, at origin: NSPoint, lineHeight: CGFloat) {
        let size: CGFloat = 8
        let centerY = origin.y + lineHeight / 2
        let centerX = origin.x + size / 2

        let chevron = NSBezierPath()
        if collapsed {
            // Right-pointing triangle
            let left = centerX - size / 4
            let right = centerX + size / 4
            let top = centerY - size / 3
            let bottom = centerY + size / 3
            chevron.move(to: NSPoint(x: left, y: top))
            chevron.line(to: NSPoint(x: right, y: centerY))
            chevron.line(to: NSPoint(x: left, y: bottom))
            chevron.close()
            NSColor.secondaryLabelColor.setFill()
        } else {
            // Down-pointing triangle
            let left = centerX - size / 3
            let right = centerX + size / 3
            let top = centerY - size / 4
            let bottom = centerY + size / 4
            chevron.move(to: NSPoint(x: left, y: top))
            chevron.line(to: NSPoint(x: right, y: top))
            chevron.line(to: NSPoint(x: centerX, y: bottom))
            chevron.close()
            NSColor.tertiaryLabelColor.setFill()
        }
        chevron.fill()
    }

    /// Draw a small play triangle button overlaying the segment bar.
    private func drawRunButton(at barRect: NSRect, color: NSColor) {
        let buttonSize: CGFloat = 16
        let buttonRect = NSRect(
            x: barRect.midX - buttonSize / 2,
            y: barRect.minY - 1,
            width: buttonSize,
            height: buttonSize
        )

        // Background circle
        let bgColor = NSColor.controlAccentColor
        bgColor.setFill()
        NSBezierPath(ovalIn: buttonRect).fill()

        // Play triangle (white)
        let triangleInset: CGFloat = 4.5
        let triLeft = buttonRect.minX + triangleInset + 1
        let triRight = buttonRect.maxX - triangleInset + 1
        let triTop = buttonRect.minY + triangleInset
        let triBottom = buttonRect.maxY - triangleInset
        let triMidY = (triTop + triBottom) / 2

        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: triLeft, y: triTop))
        triangle.line(to: NSPoint(x: triRight, y: triMidY))
        triangle.line(to: NSPoint(x: triLeft, y: triBottom))
        triangle.close()

        NSColor.white.setFill()
        triangle.fill()
    }
}
