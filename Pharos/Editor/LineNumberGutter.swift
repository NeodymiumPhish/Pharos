import AppKit
import Combine

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

    /// Lines carrying an error marker, each with the message that produced it
    /// (nil when the caller had no message to give). The message is what the
    /// marker's accessibility value reads out, and what a later phase's hover
    /// popover will show.
    private var errors: [Int: String?] = [:]

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

    // MARK: - Error Popover State

    /// Called when the user asks to go to the error on a line — the popover's
    /// "Go to Error" button. The host puts the caret on the range it marked.
    var onRevealError: ((Int) -> Void)?

    /// The error line the pointer is currently over, nil when it is over none.
    private var hoveredErrorLine: Int?

    /// The popover currently on screen, and the line it speaks for.
    private var errorPopover: NSPopover?
    private var errorPopoverLine: Int?

    /// Pending open (0.4 s dwell) and pending close (short grace) work.
    private var popoverOpenWork: DispatchWorkItem?
    private var popoverCloseWork: DispatchWorkItem?

    /// Dwell before a hover opens the popover. A pointer crossing the gutter
    /// on its way somewhere else should not fire it.
    private static let errorHoverDelay: TimeInterval = 0.4

    /// Grace after the pointer leaves the marker. Long enough to travel into
    /// the popover itself and press its button.
    private static let errorPopoverCloseDelay: TimeInterval = 0.35

    /// Horizontal metrics — everything that decides how wide the gutter is and
    /// where inside it the line numbers sit.
    ///
    /// The SQL editor's gutter carries two extra columns beside the numbers: a
    /// fold-chevron column on the left (drawn at x = 3, 14 pt wide) and a
    /// segment-bar column on the right. A host that never calls
    /// `setFoldRegions` or `setSegments` has neither, and reserving space for
    /// them is dead width — which matters in a narrow sidebar, where every
    /// point taken by the gutter is a point of value text the user cannot see.
    struct Metrics {
        /// Space left of the line numbers — the fold-chevron column.
        var leadingPadding: CGFloat
        /// Space between the line numbers and the segment-bar column.
        var numberTrailingPadding: CGFloat
        var segmentBarWidth: CGFloat
        /// Space between the line numbers' trailing padding and the bar.
        var segmentBarGap: CGFloat
        /// Width floor in digits, so the gutter does not twitch narrower on a
        /// one- or two-line document and wider on the next keystroke.
        var minimumDigits: Int

        /// The main SQL editor: both extra columns present.
        static let sqlEditor = Metrics(
            leadingPadding: 16, numberTrailingPadding: 4,
            segmentBarWidth: 4, segmentBarGap: 6, minimumDigits: 3)

        /// The variables panel's value editor: no chevrons, no segment bars,
        /// and a two-digit floor — a variable value that runs past 99 lines is
        /// not what this editor is for.
        static let compact = Metrics(
            leadingPadding: 4, numberTrailingPadding: 5,
            segmentBarWidth: 0, segmentBarGap: 0, minimumDigits: 2)
    }

    private let metrics: Metrics

    // MARK: - Pulse State

    /// Set of segment indices currently executing (-1 = full-editor phantom, >= 0 = specific segment).
    private var runningSegmentIndices: Set<Int> = []   // includes -1 for phantom/direct-SQL

    /// Per-index fade-out state, keyed by segment index (including -1 for phantom).
    private var fadeOutStates: [Int: FadeState] = [:]

    private struct FadeState {
        let startAlpha: CGFloat
        let endTime: CFTimeInterval
    }

    /// Subscription to PulseClock while pulsing (including fade-out).
    private var pulseSubscription: AnyCancellable?

    /// Current pulse value [0, 1] read from PulseClock.
    private var pulseValue: CGFloat = 1.0

    /// Duration of the completion fade-out, in seconds.
    private let fadeOutDuration: CFTimeInterval = 0.25

    private var gutterTrackingArea: NSTrackingArea?

    /// Cached character offsets of each line start for O(1) line-number lookups.
    /// Element i holds the character index where line (i+1) begins; lineStarts[0] is always 0.
    private var lineStarts: [Int] = [0]

    /// Cached glyph width for a single digit using `lineAttributes`. The font
    /// is fixed for the gutter's lifetime, so this is computed once at init
    /// instead of constructing an NSAttributedString and calling .size() per
    /// keystroke inside recalculateWidth.
    private var cachedDigitWidth: CGFloat = 8

    /// Last digit count for which we computed and reported `desiredWidth`.
    /// `recalculateWidth` short-circuits when the count hasn't changed,
    /// avoiding the `onWidthChange` notification (and the host VC's layout
    /// pass) on every keystroke that doesn't cross a power-of-ten boundary.
    private var lastDigitCount: Int = 0

    init(textView: NSTextView, scrollView: NSScrollView, metrics: Metrics = .sqlEditor) {
        self.textView = textView
        self.scrollView = scrollView
        self.metrics = metrics
        super.init(frame: .zero)

        applyNumberFont(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular))

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
        // The error marker changes shape under "Differentiate without colour",
        // so it has to be repainted when the user flips that switch.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityDisplayDidChange(_:)),
            name: AccessibilityDisplay.didChange, object: nil
        )

        setAccessibilityIdentifier("editor.gutter")

        rebuildLineStarts()
        // Resolve the width from `metrics` now rather than leaving the stored
        // default standing until the first keystroke: a host reads
        // `desiredWidth` in its very first layout pass, and with a per-host
        // metric set there is no single default that could be right for it.
        // `onWidthChange` is still nil here, so this cannot call back out
        // into a host that has not finished building itself.
        recalculateWidth()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        popoverOpenWork?.cancel()
        popoverCloseWork?.cancel()
    }

    // MARK: - Public API

    /// Follow the editor font. The numbers use the system monospaced-digit
    /// face one point smaller than the editor text (never below 9 pt), so a
    /// 16 pt editor does not sit beside 11 pt numbers. Resets the cached
    /// digit width and the width short-circuit so `desiredWidth` is
    /// recomputed for the new size, then redraws.
    func setFont(_ editorFont: NSFont) {
        let size = max(9, editorFont.pointSize - 1)
        applyNumberFont(NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular))
        lastDigitCount = 0
        recalculateWidth()
        needsDisplay = true
    }

    private func applyNumberFont(_ font: NSFont) {
        lineAttributes = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        cachedDigitWidth = NSAttributedString(string: "8", attributes: lineAttributes).size().width
    }

    /// The number font in force — `lineAttributes[.font]`, typed.
    private var numberFont: NSFont {
        (lineAttributes[.font] as? NSFont) ?? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    /// Mark error lines, each with the message that caused it. A nil message
    /// means "an error here, text unknown" — the marker still draws and still
    /// reads out, just as "Error".
    func setErrors(_ newErrors: [Int: String?]) {
        errors = newErrors
        errorsDidChange()
    }

    /// Message-free form, kept for callers that only know the line.
    func setErrorLines(_ lines: Set<Int>) {
        setErrors(Dictionary(uniqueKeysWithValues: lines.map { ($0, nil) }))
    }

    func clearErrors() {
        errors.removeAll()
        errorsDidChange()
    }

    /// The message recorded for `line`, or nil when the line has no error or
    /// the error arrived without one.
    func errorMessage(forLine line: Int) -> String? {
        errors[line] ?? nil
    }

    private func errorsDidChange() {
        // A popover still naming a line that no longer carries an error would
        // sit there quoting a message the editor has already retracted.
        if let shown = errorPopoverLine, !errors.keys.contains(shown) {
            dismissErrorPopover()
        }
        hoveredErrorLine = nil
        needsDisplay = true
        accessibilityStructureDidChange()
    }

    /// Force a redraw — call after programmatic text changes (e.g. setSQL).
    func invalidateLineNumbers() {
        rebuildLineStarts()
        recalculateWidth()
        needsDisplay = true
    }

    /// Update the segment data. Called by the host VC when text changes or cursor moves.
    func setSegments(_ newSegments: [SQLSegment], activeIndex: Int?) {
        segments = newSegments
        activeSegmentIndex = activeIndex
        // Drop orphan fade-out entries that no longer correspond to a real segment.
        let validIndices = Set(segments.indices).union([-1])
        fadeOutStates = fadeOutStates.filter { validIndices.contains($0.key) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        accessibilityStructureDidChange()
    }

    /// Set the currently-executing segment indices.
    /// - Empty set = idle (stops pulsing with a fade-out per removed index)
    /// - Contains -1 = full-editor phantom (pulses the entire gutter bar)
    /// - Contains >= 0 = specific segments pulse in unison
    func setRunningSegmentIndices(_ indices: Set<Int>) {
        let removed = runningSegmentIndices.subtracting(indices)
        for idx in removed {
            fadeOutStates[idx] = FadeState(
                startAlpha: currentPulseAlpha(),
                endTime: CACurrentMediaTime() + fadeOutDuration
            )
        }
        runningSegmentIndices = indices
        if !indices.isEmpty {
            if pulseSubscription == nil {
                pulseSubscription = Self.composedPulseSubscription { [weak self] v in
                    self?.pulseValue = v
                    self?.needsDisplay = true
                }
            }
        } else if fadeOutStates.isEmpty {
            pulseSubscription = nil
        }
        needsDisplay = true
    }

    /// Compose a `PulseClock` subscription that retains the `observe()` token
    /// alongside the `sink` cancellable, so cancelling one cancels both.
    private static func composedPulseSubscription(
        onValue: @escaping (CGFloat) -> Void
    ) -> AnyCancellable {
        let token = PulseClock.shared.observe()
        let sub = PulseClock.shared.value.sink(receiveValue: onValue)
        return AnyCancellable {
            sub.cancel()
            token.cancel()
        }
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
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        accessibilityStructureDidChange()
    }

    // MARK: - Line Start Cache

    /// Rebuild the cached line-start offsets from the full text.
    private func rebuildLineStarts() {
        guard let textView else {
            lineStarts = [0]
            return
        }
        let text = textView.string
        var starts = [0]
        starts.reserveCapacity(text.utf16.count / 40 + 1)  // rough estimate
        for (i, ch) in text.utf16.enumerated() {
            if ch == 0x0A {
                starts.append(i + 1)
            }
        }
        lineStarts = starts
    }

    /// Binary search on `lineStarts` to find the 1-based line number for a character index.
    private func lineNumber(forCharacterIndex index: Int) -> Int {
        var lo = 0, hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo  // 1-based line number
    }

    // MARK: - Line Y (gutter-space)

    /// Converts a line-fragment rect from text-*container* coordinates into
    /// this gutter's own (flipped) coordinate space via the real view
    /// hierarchy (`NSView.convert(_:to:)`), instead of hand-deriving the text
    /// view's scroll offset from `scrollView.contentView.bounds.origin.y` and
    /// adding the inset by arithmetic.
    ///
    /// That arithmetic assumes the text view's frame sits at a fixed,
    /// predictable position relative to its clip view — true whenever the
    /// scroll view is in its ordinary, freshly-tiled state, but NOT
    /// guaranteed in general. Measured directly: a `VariableDetailVC` value
    /// editor, built from a standalone TextKit stack and given its text via
    /// `textView.string = …` (never through the interactive editing path),
    /// can end up with `scrollView.contentView.bounds.origin.y` nonzero with
    /// no scrolling having occurred — the old formula then placed every line
    /// number a fixed amount below the line it labels, which is exactly the
    /// "number sits below its line of text" symptom. Real coordinate
    /// conversion asks AppKit where the glyph actually paints, so it is
    /// correct regardless of why the text view's own geometry ended up where
    /// it did — including genuine scrolling, which it also handles.
    private func gutterY(forTextContainerRect rect: NSRect) -> CGFloat? {
        guard let textView else { return nil }
        var inViewCoords = rect
        inViewCoords.origin.x += textView.textContainerInset.width
        inViewCoords.origin.y += textView.textContainerInset.height
        return textView.convert(inViewCoords, to: self).origin.y
    }

    /// The part of the text the user can currently see, in text-*container*
    /// coordinates — the exact inverse of `gutterY(forTextContainerRect:)`, and
    /// wrong in exactly the same way if hand-derived instead of converted.
    ///
    /// The arithmetic this replaces was
    /// `NSRect(y: scrollView.contentView.bounds.origin.y, height: contentView.bounds.height)`,
    /// which assumes the clip view's bounds origin *is* the offset into the
    /// text container. Measured on a `VariableDetailVC` value editor holding 30
    /// lines: the clip view's `bounds.origin.y` and the text view's
    /// `frame.origin.y` are both large negative numbers (-339 and -398), so
    /// that rect lands entirely above the text and
    /// `glyphRange(forBoundingRect:)` collapses to almost nothing. The line
    /// numbers then stop partway down the editor and leave unnumbered rows
    /// below them — and, from the same walk, the segment bars stop with them.
    /// Real coordinate conversion asks AppKit which text is on screen, so it
    /// holds however the scroll view's geometry ended up.
    private func visibleTextContainerRect() -> NSRect? {
        guard let textView, let scrollView else { return nil }
        var rect = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        rect.origin.x -= textView.textContainerInset.width
        rect.origin.y -= textView.textContainerInset.height
        return rect
    }

    /// The character range of the text currently on screen. Internal (not
    /// `private`) as a test seam: PharosTests/VariableDetailVCTests.swift
    /// checks that the lines this covers are the same lines that `y(forLine:)`
    /// places inside the gutter's own bounds — the two must not disagree, or
    /// visible rows go unnumbered.
    func visibleCharacterRange() -> NSRange? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let rect = visibleTextContainerRect() else { return nil }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// The y, in this gutter's own coordinate space, at which the given
    /// 1-based line's text visually renders. Internal (not `private`) purely
    /// as a test seam: PharosTests/VariableDetailVCTests.swift calls this and
    /// independently measures the same line's real screen position via its
    /// own `NSView.convert(_:to:)` call, to confirm the two agree — a
    /// hand-duplicated copy of `gutterY(forTextContainerRect:)` in the test
    /// would pass even if both copies shared the same bug, which is why the
    /// test computes ground truth via the view hierarchy instead of via this
    /// gutter's formula.
    func y(forLine line: Int) -> CGFloat? {
        guard let textView, let layoutManager = textView.layoutManager,
              line >= 1, line <= lineStarts.count else { return nil }
        let text = textView.string as NSString
        let charIndex = min(lineStarts[line - 1], text.length)
        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        return gutterY(forTextContainerRect: lineRect)
    }

    // MARK: - Notifications

    @objc private func textDidChange(_: Notification) {
        rebuildLineStarts()
        recalculateWidth()
        needsDisplay = true
    }

    @objc private func boundsDidChange(_: Notification) {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    @objc private func accessibilityDisplayDidChange(_: Notification) {
        needsDisplay = true
    }

    @objc private func selectionDidChange(_: Notification) {
        guard let textView else { return }
        let cursor = textView.selectedRange().location
        let line = lineNumber(forCharacterIndex: min(cursor, textView.string.utf16.count))
        if currentLine != line {
            currentLine = line
            needsDisplay = true
        }
    }

    // MARK: - Width

    private func recalculateWidth() {
        // `rebuildLineStarts` runs before this on every text change, so the
        // cache size equals the current line count — no need for a second
        // O(N) walk just to recount newlines. Short-circuit when the digit
        // count hasn't changed: that's the only thing that moves the gutter
        // width, and crossing 99→100→1000 is a rare event compared to typing.
        let lineCount = max(lineStarts.count, 1)
        let digits = max(String(lineCount).count, metrics.minimumDigits)
        guard digits != lastDigitCount else { return }
        lastDigitCount = digits

        let newWidth = metrics.leadingPadding + CGFloat(digits) * cachedDigitWidth
            + metrics.numberTrailingPadding + metrics.segmentBarWidth + metrics.segmentBarGap
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

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString
        guard text.length > 0, let visibleCharRange = visibleCharacterRange() else { return }

        // Build line → y map for visible lines
        var charIndex = visibleCharRange.location
        var lineNum = 1
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in lineNum += 1 }

        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            guard let y = gutterY(forTextContainerRect: lineRect) else {
                lineNum += 1
                charIndex = NSMaxRange(lineRange)
                continue
            }

            // Fold chevron cursor (leftmost 14pt)
            if foldRegions.contains(where: { $0.startLine == lineNum }) {
                let chevronRect = NSRect(x: 0, y: y, width: 14, height: lineRect.height)
                addCursorRect(chevronRect, cursor: .pointingHand)
            }

            // Segment run button cursor (rightmost bar column)
            let barColumnX = desiredWidth - metrics.segmentBarGap - metrics.segmentBarWidth
            if segments.contains(where: { lineNum >= $0.startLine && lineNum <= $0.endLine }) {
                let barRect = NSRect(x: barColumnX - 4, y: y, width: metrics.segmentBarWidth + 8, height: lineRect.height)
                addCursorRect(barRect, cursor: .pointingHand)
            }

            lineNum += 1
            charIndex = NSMaxRange(lineRange)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInGutter = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let barColumnX = desiredWidth - metrics.segmentBarGap - metrics.segmentBarWidth

        // Track mouse-in-gutter for fold chevron visibility
        if !mouseInGutter {
            mouseInGutter = true
            needsDisplay = true
        }

        updateErrorHover(at: point)

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
        hoveredErrorLine = nil
        cancelPopoverOpen()
        scheduleErrorPopoverClose()
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

        // A click on the error marker opens its popover at once — no dwell.
        if let line = errorLine(at: point) {
            cancelPopoverOpen()
            cancelPopoverClose()
            presentErrorPopover(line: line)
            return
        }

        let barColumnX = desiredWidth - metrics.segmentBarGap - metrics.segmentBarWidth

        // Only handle clicks in the segment bar column
        guard point.x >= barColumnX - 4,
              let idx = hoveredSegmentIndex,
              idx < segments.count else {
            super.mouseDown(with: event)
            return
        }

        onRunSegment?(segments[idx])
    }

    /// Map a point (in gutter coordinates) to a 1-based line number. The
    /// inverse of `gutterY(forTextContainerRect:)`: converts the point into
    /// the text view's own coordinate space via the real view hierarchy,
    /// then subtracts the container inset to land in text-container
    /// coordinates, rather than re-deriving the text view's position from
    /// the scroll offset by hand.
    private func lineNumber(at point: NSPoint) -> Int {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 0 }

        let text = textView.string as NSString
        guard text.length > 0 else { return 1 }

        let pointInTextView = convert(point, to: textView)
        let testPoint = NSPoint(
            x: pointInTextView.x - textView.textContainerInset.width,
            y: pointInTextView.y - textView.textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: testPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        // Binary search on cached line starts for O(1) lookup
        return lineNumber(forCharacterIndex: min(charIndex, text.length))
    }

    // MARK: - Error Popover

    /// The 1-based error line whose marker `point` (gutter coordinates) is
    /// over, or nil when the point is over no marker. The hit box is the
    /// painted marker grown a few points, so the pointer does not have to land
    /// inside a 10 pt disc.
    private func errorLine(at point: NSPoint) -> Int? {
        guard !errors.isEmpty, point.x < Self.errorMarkerSize + 6 else { return nil }
        let line = lineNumber(at: point)
        guard errors.keys.contains(line),
              let frame = lineFrame(forLine: line) else { return nil }
        let hit = errorMarkerRect(lineTop: frame.origin.y, lineHeight: frame.height)
            .insetBy(dx: -3, dy: -2)
        return hit.contains(point) ? line : nil
    }

    /// Track the pointer over the error markers: entering one arms the dwell
    /// timer, leaving one hands the open popover its grace period.
    private func updateErrorHover(at point: NSPoint) {
        let line = errorLine(at: point)
        guard line != hoveredErrorLine else { return }
        hoveredErrorLine = line

        cancelPopoverOpen()
        guard let line else {
            scheduleErrorPopoverClose()
            return
        }
        cancelPopoverClose()
        // Already showing this line's message — nothing to re-open.
        guard errorPopoverLine != line else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredErrorLine == line else { return }
            self.presentErrorPopover(line: line)
        }
        popoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorHoverDelay, execute: work)
    }

    private func cancelPopoverOpen() {
        popoverOpenWork?.cancel()
        popoverOpenWork = nil
    }

    private func cancelPopoverClose() {
        popoverCloseWork?.cancel()
        popoverCloseWork = nil
    }

    /// Close the popover after a short grace. The pointer leaving the marker is
    /// usually the pointer travelling INTO the popover to press its button, so
    /// a closing pass that finds the pointer inside the popover's own window
    /// re-arms itself instead of shutting the button away.
    private func scheduleErrorPopoverClose() {
        guard errorPopover != nil else { return }
        cancelPopoverClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let popover = self.errorPopover else { return }
            self.popoverCloseWork = nil
            if self.hoveredErrorLine != nil { return }
            if let popoverWindow = popover.contentViewController?.view.window,
               popoverWindow.frame.contains(NSEvent.mouseLocation) {
                self.scheduleErrorPopoverClose()
                return
            }
            self.dismissErrorPopover()
        }
        popoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorPopoverCloseDelay, execute: work)
    }

    func dismissErrorPopover() {
        cancelPopoverOpen()
        cancelPopoverClose()
        errorPopover?.performClose(nil)
        errorPopover = nil
        errorPopoverLine = nil
    }

    /// Build the popover's content for `line`, or nil when that line carries no
    /// error. Internal as a test seam: the popover itself needs a window, the
    /// content it carries does not.
    func makeErrorPopoverContent(forLine line: Int) -> ErrorPopoverVC? {
        guard errors.keys.contains(line) else { return nil }
        let content = ErrorPopoverVC(
            line: line,
            message: errorMessage(forLine: line) ?? "Error"
        )
        content.onGoToError = { [weak self] in
            guard let self else { return }
            self.dismissErrorPopover()
            self.onRevealError?(line)
        }
        return content
    }

    /// Show the message for `line` beside its marker. A no-op when the line has
    /// no error, or when the gutter is not in a window (nothing to anchor to).
    /// Internal as a test seam — the accessibility element's press calls it too.
    @discardableResult
    func presentErrorPopover(line: Int) -> Bool {
        guard let content = makeErrorPopoverContent(forLine: line) else { return false }
        guard window != nil, let frame = lineFrame(forLine: line) else { return false }

        dismissErrorPopover()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = content
        let anchor = errorMarkerRect(lineTop: frame.origin.y, lineHeight: frame.height)
            .insetBy(dx: -2, dy: -2)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
        errorPopover = popover
        errorPopoverLine = line
        return true
    }

    /// The popover's content: the failure text, wrapped and selectable, over a
    /// button that puts the caret on the offending SQL.
    final class ErrorPopoverVC: NSViewController {

        let line: Int
        let message: String
        var onGoToError: (() -> Void)?

        /// Test seams — the assertions read the text the popover will show and
        /// press the button it will offer.
        private(set) var messageLabel = NSTextField(wrappingLabelWithString: "")
        private(set) var goToErrorButton = NSButton(title: "Go to Error", target: nil, action: nil)

        /// Text wider than this wraps rather than stretching the popover into
        /// the next display — a PostgreSQL message can be a paragraph.
        static let maxContentWidth: CGFloat = 420

        /// …and narrower than this it does NOT wrap. A wrapping label left to
        /// pick its own width settles on a very narrow column (measured: 128 pt
        /// beside the live gutter), which turns a one-sentence message into
        /// eight stacked fragments. The floor only applies once there is enough
        /// text to need it, so a three-word message still gets a small popover.
        static let minContentWidth: CGFloat = 260

        init(line: Int, message: String) {
            self.line = line
            self.message = message
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not implemented")
        }

        override func loadView() {
            let container = NSView()

            messageLabel.stringValue = message
            messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            messageLabel.textColor = .labelColor
            messageLabel.isSelectable = true
            messageLabel.maximumNumberOfLines = 0
            messageLabel.lineBreakMode = .byWordWrapping
            messageLabel.preferredMaxLayoutWidth = Self.maxContentWidth
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            messageLabel.setAccessibilityLabel("Error on line \(line)")

            goToErrorButton.target = self
            goToErrorButton.action = #selector(goToErrorClicked)
            goToErrorButton.bezelStyle = .rounded
            goToErrorButton.controlSize = .small
            goToErrorButton.font = .systemFont(ofSize: 11)
            goToErrorButton.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(messageLabel)
            container.addSubview(goToErrorButton)

            // Only claim the floor when the text actually needs more than it —
            // measured at the unwrapped width, since a wrapping label's
            // intrinsic size is the single-line size until a width is imposed.
            let unwrappedWidth = (message as NSString).size(
                withAttributes: [.font: messageLabel.font ?? NSFont.systemFont(ofSize: 12)]).width
            if unwrappedWidth > Self.minContentWidth {
                let floor = messageLabel.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: Self.minContentWidth)
                floor.priority = .defaultHigh
                floor.isActive = true
            }

            NSLayoutConstraint.activate([
                messageLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentWidth),

                goToErrorButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
                goToErrorButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                goToErrorButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
                container.trailingAnchor.constraint(greaterThanOrEqualTo: goToErrorButton.trailingAnchor, constant: 12),
            ])

            view = container
        }

        @objc private func goToErrorClicked() {
            onGoToError?()
        }

        /// Test seam: fire the button's action without a mouse.
        func performGoToError() {
            goToErrorClicked()
        }
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let text = textView.string as NSString

        // Background — seamless with editor (no visible boundary)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // Prepare attributes for current-line vs normal line numbers
        let normalAttributes = lineAttributes
        var activeAttributes = lineAttributes
        activeAttributes[.foregroundColor] = NSColor.labelColor

        // Baseline alignment. A number centred in its line fragment sits on a
        // different baseline from the text whenever the two fonts differ in
        // ascent (they do: system monospaced digits beside JetBrains Mono, or
        // beside a larger editor size). So place each number by baseline: the
        // fragment's baseline comes from the layout manager, the number's from
        // the same default-baseline rule NSStringDrawing applies to `draw(at:)`.
        let numberBaseline = layoutManager.defaultBaselineOffset(for: numberFont)
        let numberX = desiredWidth - metrics.segmentBarWidth - metrics.segmentBarGap
            - metrics.numberTrailingPadding
        func drawNumber(_ lineNumber: Int, lineTop y: CGFloat, lineHeight: CGFloat, textBaseline: CGFloat) {
            let attrs = (lineNumber == currentLine) ? activeAttributes : normalAttributes
            let attrString = NSAttributedString(string: "\(lineNumber)", attributes: attrs)
            let stringSize = attrString.size()
            // Baseline of the text line, in gutter coordinates, minus the
            // number's own baseline offset gives the number's top. Fall back
            // to centring only if the layout manager gave no baseline.
            let top = textBaseline > 0
                ? y + textBaseline - numberBaseline
                : y + (lineHeight - stringSize.height) / 2
            attrString.draw(at: NSPoint(x: numberX - stringSize.width, y: top))
        }

        // Visible range in the text view — see `visibleTextContainerRect()`.
        guard let visibleCharRange = visibleCharacterRange() else { return }

        // Starting line number: O(log N) lookup into the cached lineStarts
        // instead of an O(N) per-redraw walk via enumerateSubstrings.
        var lineNumber = lineNumber(forCharacterIndex: visibleCharRange.location)

        // Build a map of line number → y position and line height for segment bar drawing
        var lineYPositions: [(line: Int, y: CGFloat, height: CGFloat)] = []

        // Draw line numbers for visible lines
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))

            // Skip lines hidden inside a collapsed fold. The fold's startLine
            // remains visible (it shows the chevron + pill), but every line
            // between startLine and endLine collapses to the anchor's y in
            // the layout manager, which would stack their line numbers on
            // top of each other if we drew them.
            let isHiddenByFold = foldRegions.contains { region in
                region.isCollapsed && lineNumber > region.startLine && lineNumber <= region.endLine
            }
            if isHiddenByFold {
                lineNumber += 1
                charIndex = NSMaxRange(lineRange)
                continue
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

            // y position in our coordinate space, via real view-hierarchy
            // coordinate conversion — see `gutterY(forTextContainerRect:)`.
            guard let y = gutterY(forTextContainerRect: lineRect) else {
                lineNumber += 1
                charIndex = NSMaxRange(lineRange)
                continue
            }

            lineYPositions.append((line: lineNumber, y: y, height: lineRect.height))

            // Error indicator — a red dot normally, a red exclamation-mark
            // symbol when the user asked not to be told things by colour
            // alone, so the marker still reads at a glance in monochrome.
            if errors.keys.contains(lineNumber) {
                drawErrorMarker(lineTop: y, lineHeight: lineRect.height)
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

            // Line number text — right-aligned before the segment bar column,
            // on the line's baseline. `location(forGlyphAt:)` is the glyph's
            // origin within its fragment; its y is the baseline offset — for a
            // glyph that draws. A line holding only its newline reports the
            // fragment HEIGHT there (measured: 19 for a 15 baseline), so an
            // empty line's number sat a few points low. Fall back to the
            // font's default baseline, which is what the typesetter used.
            let fontBaseline = layoutManager.defaultBaselineOffset(for: textView.font ?? numberFont)
            var textBaseline = fontBaseline
            if glyphRange.location < layoutManager.numberOfGlyphs {
                let reported = layoutManager.location(forGlyphAt: glyphRange.location).y
                if reported > 0, reported < lineRect.height { textBaseline = reported }
            }
            drawNumber(lineNumber, lineTop: y, lineHeight: lineRect.height, textBaseline: textBaseline)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        // The trailing line. An empty document, and a document that ends in a
        // newline, both end in a line with NO glyphs, so the glyph-based
        // visible range never reaches it and the loop above never numbers it
        // — a fresh tab showed no "1", and the caret's last line had no
        // number. The layout manager keeps that line's geometry in
        // `extraLineFragmentRect`; number it from there when the walk has
        // reached the end of the text.
        if lineNumber == lineStarts.count,
           text.length == 0 || text.character(at: text.length - 1) == 0x0A,
           !layoutManager.extraLineFragmentRect.isEmpty,
           let y = gutterY(forTextContainerRect: layoutManager.extraLineFragmentRect) {
            let extra = layoutManager.extraLineFragmentRect
            drawNumber(lineNumber, lineTop: y, lineHeight: extra.height,
                       textBaseline: layoutManager.defaultBaselineOffset(for: textView.font ?? numberFont))
        }

        // Draw segment bars / phantom pulse
        guard !lineYPositions.isEmpty,
              let firstEntry = lineYPositions.first,
              let lastEntry = lineYPositions.last else { return }

        let barX = desiredWidth - metrics.segmentBarGap / 2 - metrics.segmentBarWidth
        let firstVisibleLine = firstEntry.line
        let lastVisibleLine = lastEntry.line

        // Build lookup dictionary for O(1) line → position mapping
        var linePositionMap: [Int: (y: CGFloat, height: CGFloat)] = [:]
        linePositionMap.reserveCapacity(lineYPositions.count)
        for entry in lineYPositions {
            linePositionMap[entry.line] = (entry.y, entry.height)
        }

        let now = CACurrentMediaTime()

        for (segIdx, segment) in segments.enumerated() {
            // Skip segments that don't overlap the visible line range
            guard segment.endLine >= firstVisibleLine && segment.startLine <= lastVisibleLine else { continue }

            let clampedStart = max(segment.startLine, firstVisibleLine)
            let clampedEnd = min(segment.endLine, lastVisibleLine)

            guard let startEntry = linePositionMap[clampedStart],
                  let endEntry = linePositionMap[clampedEnd] else { continue }

            let barY = startEntry.y + 2
            let barBottom = endEntry.y + endEntry.height - 2
            let barHeight = max(barBottom - barY, 4)

            // Determine bar color — pulse takes precedence for running segments.
            let barColor: NSColor
            if runningSegmentIndices.contains(segIdx) {
                barColor = NSColor.controlAccentColor.withAlphaComponent(currentPulseAlpha())
            } else if let fade = fadeOutStates[segIdx] {
                let remaining = fade.endTime - now
                if remaining > 0 {
                    let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
                    barColor = NSColor.controlAccentColor.withAlphaComponent(fade.startAlpha * (1.0 - progress))
                } else {
                    fadeOutStates.removeValue(forKey: segIdx)
                    barColor = defaultBarColor(for: segIdx)
                }
            } else {
                barColor = defaultBarColor(for: segIdx)
            }

            let barRect = NSRect(x: barX, y: barY, width: metrics.segmentBarWidth, height: barHeight)
            barColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()

            if segIdx == hoveredSegmentIndex {
                drawRunButton(at: barRect, color: barColor)
            }
        }

        // Phantom pulse for direct-SQL execution (segmentIndex == -1).
        if runningSegmentIndices.contains(-1), lineYPositions.count >= 1 {
            let top = lineYPositions.first!.y + 2
            let bottomEntry = lineYPositions.last!
            let bottom = bottomEntry.y + bottomEntry.height - 2
            let phantomRect = NSRect(x: barX, y: top, width: metrics.segmentBarWidth, height: max(bottom - top, 4))
            NSColor.controlAccentColor.withAlphaComponent(currentPulseAlpha()).setFill()
            NSBezierPath(roundedRect: phantomRect, xRadius: 2, yRadius: 2).fill()
        } else if let fade = fadeOutStates[-1], lineYPositions.count >= 1 {
            let remaining = fade.endTime - now
            if remaining > 0 {
                let top = lineYPositions.first!.y + 2
                let bottomEntry = lineYPositions.last!
                let bottom = bottomEntry.y + bottomEntry.height - 2
                let phantomRect = NSRect(x: barX, y: top, width: metrics.segmentBarWidth, height: max(bottom - top, 4))
                let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
                NSColor.controlAccentColor.withAlphaComponent(fade.startAlpha * (1.0 - progress)).setFill()
                NSBezierPath(roundedRect: phantomRect, xRadius: 2, yRadius: 2).fill()
            } else {
                fadeOutStates.removeValue(forKey: -1)
            }
        }

        // Drive fade-out redraws. Pulse subscription stops in setRunningSegmentIndices
        // when indices clear; fade-out redraws keep ticking until all fades expire.
        if !fadeOutStates.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
    }

    /// Current pulse alpha — the value all running bars share off the shared
    /// pulse clock. Used both for live pulse rendering and as the snapshot value
    /// when a bar enters its fade-out state.
    private func currentPulseAlpha() -> CGFloat {
        0.55 + 0.45 * pulseValue
    }

    /// Fallback bar color: result-tab color first, then active-segment highlight, then idle tertiary.
    private func defaultBarColor(for segIdx: Int) -> NSColor {
        if let resultColor = segmentColors[segIdx] {
            return resultColor
        } else if segIdx == activeSegmentIndex {
            return NSColor.controlAccentColor
        } else {
            return NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
        }
    }

    /// Gutter-space rect of the error marker on a line whose fragment starts
    /// at `lineTop` and is `lineHeight` tall. Both marker shapes share the
    /// box, so the accessibility frame does not move when the shape changes.
    private func errorMarkerRect(lineTop y: CGFloat, lineHeight: CGFloat) -> NSRect {
        let size = Self.errorMarkerSize
        return NSRect(x: 1, y: y + (lineHeight - size) / 2, width: size, height: size)
    }

    private static let errorMarkerSize: CGFloat = 10

    /// Paint the error marker. Under "Differentiate without colour" the marker
    /// is an exclamation mark in a circle — a shape, not only a red patch.
    private func drawErrorMarker(lineTop y: CGFloat, lineHeight: CGFloat) {
        let box = errorMarkerRect(lineTop: y, lineHeight: lineHeight)
        let byShape = MainActor.assumeIsolated {
            AccessibilityDisplay.shared.differentiateWithoutColor
        }
        if byShape,
           let symbol = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                accessibilityDescription: "Error") {
            symbol.isTemplate = true
            let tinted = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? symbol
            tinted.draw(in: box)
            return
        }
        let dotSize: CGFloat = 6
        let dotRect = NSRect(
            x: 3,
            y: y + (lineHeight - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    /// Draw a fold disclosure chevron (right-pointing when collapsed, down-pointing when expanded).
    private func drawFoldChevron(collapsed: Bool, at origin: NSPoint, lineHeight: CGFloat) {
        let size: CGFloat = 12
        let centerY = origin.y + lineHeight / 2
        let centerX = origin.x + 7 // center within the 14pt click column

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

    // MARK: - Accessibility

    /// A gutter control as VoiceOver sees it. The gutter paints its run
    /// buttons, fold chevrons and error markers itself, so there is no
    /// subview for the accessibility system to find — one of these stands in
    /// for each of them, carrying the action to run when the user presses it.
    final class GutterElement: NSAccessibilityElement {

        /// What the element does on press. Returns false when the thing it
        /// pointed at is gone (the text changed under a held focus).
        var onPress: (() -> Bool)?

        override func accessibilityPerformPress() -> Bool {
            onPress?() ?? false
        }
    }

    /// Cached child elements, keyed by what they stand for ("run-2",
    /// "fold-0", "error-7"). VoiceOver holds on to the element it is focused
    /// on, so the SAME object has to come back for the same control across
    /// redraws — a fresh element per call would drop focus on every keystroke.
    private var cachedAccessibilityElements: [String: GutterElement] = [:]

    /// Tell the accessibility system the set of controls changed. Called when
    /// segments, fold regions or errors move.
    private func accessibilityStructureDidChange() {
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Line gutter" }

    override func accessibilityChildren() -> [Any]? {
        rebuildAccessibilityElements()
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        for element in rebuildAccessibilityElements()
        where element.accessibilityFrame().contains(point) {
            return element
        }
        return self
    }

    /// Rebuild the child list from current state, reusing cached elements by
    /// key and dropping keys that no longer stand for anything. Frames are
    /// refreshed every call, since scrolling and editing move every control.
    ///
    /// Internal (not private) as a test seam:
    /// PharosTests/GutterAccessibilityTests.swift drives it directly rather
    /// than through `accessibilityChildren()`'s `[Any]?`.
    @discardableResult
    func rebuildAccessibilityElements() -> [GutterElement] {
        // (line, column order, element) so the list reads top-to-bottom and,
        // within a line, left-to-right: chevron, error marker, run button.
        var ordered: [(line: Int, column: Int, element: GutterElement)] = []
        var live = Set<String>()

        for (idx, region) in foldRegions.enumerated() {
            let key = "fold-\(idx)"
            live.insert(key)
            let element = cachedElement(forKey: key, role: .disclosureTriangle)
            element.setAccessibilityLabel(Self.rangeLabel("Fold", region.startLine, region.endLine))
            element.setAccessibilityValue(NSNumber(value: region.isCollapsed ? 0 : 1))
            element.onPress = { [weak self] in
                guard let self, idx < self.foldRegions.count else { return false }
                self.onToggleFold?(idx)
                return true
            }
            let frame = lineFrame(forLine: region.startLine).map {
                NSRect(x: 0, y: $0.origin.y, width: 14, height: $0.height)
            }
            apply(frame: frame, to: element)
            ordered.append((region.startLine, 0, element))
        }

        for line in errors.keys.sorted() {
            let key = "error-\(line)"
            live.insert(key)
            let element = cachedElement(forKey: key, role: .image)
            element.setAccessibilityLabel("Error on line \(line)")
            element.setAccessibilityValue(errorMessage(forLine: line) ?? "Error")
            // Pressing the marker is the keyboard path to the popover: a
            // VoiceOver user cannot hover, and the "Go to Error" button inside
            // it is the only way from the marker to the faulty SQL.
            element.onPress = { [weak self] in
                self?.presentErrorPopover(line: line) ?? false
            }
            let frame = lineFrame(forLine: line).map {
                errorMarkerRect(lineTop: $0.origin.y, lineHeight: $0.height)
            }
            apply(frame: frame, to: element)
            ordered.append((line, 1, element))
        }

        for (idx, segment) in segments.enumerated() {
            let key = "run-\(idx)"
            live.insert(key)
            let element = cachedElement(forKey: key, role: .button)
            element.setAccessibilityLabel(Self.rangeLabel("Run", segment.startLine, segment.endLine))
            element.onPress = { [weak self] in
                guard let self, idx < self.segments.count else { return false }
                self.onRunSegment?(self.segments[idx])
                return true
            }
            apply(frame: runButtonFrame(forLine: segment.startLine), to: element)
            ordered.append((segment.startLine, 2, element))
        }

        cachedAccessibilityElements = cachedAccessibilityElements.filter { live.contains($0.key) }

        ordered.sort { ($0.line, $0.column) < ($1.line, $1.column) }
        return ordered.map(\.element)
    }

    /// "Run lines 3–7" / "Run line 3" — a one-line statement should not be
    /// read out as a range of itself.
    private static func rangeLabel(_ verb: String, _ startLine: Int, _ endLine: Int) -> String {
        startLine == endLine
            ? "\(verb) line \(startLine)"
            : "\(verb) lines \(startLine)\u{2013}\(endLine)"
    }

    /// The cached element for `key`, created (with its role and parent fixed
    /// for life) on first use.
    private func cachedElement(forKey key: String, role: NSAccessibility.Role) -> GutterElement {
        if let existing = cachedAccessibilityElements[key] { return existing }
        let element = GutterElement()
        element.setAccessibilityRole(role)
        element.setAccessibilityParent(self)
        // NSAccessibilityElement starts out disabled, and VoiceOver will not
        // press a disabled control — measured on the live app, where the run
        // buttons first came back as AXEnabled = false.
        element.setAccessibilityEnabled(true)
        cachedAccessibilityElements[key] = element
        return element
    }

    /// Give an element its frame. The accessibility system works in SCREEN
    /// coordinates, so a hosted gutter converts through the window; an
    /// unhosted one (a test harness, or a view not yet in a window) has no
    /// screen position to convert to and reports the parent-space rect
    /// instead.
    private func apply(frame: NSRect?, to element: GutterElement) {
        guard let frame else {
            element.setAccessibilityFrameInParentSpace(.zero)
            return
        }
        if let window {
            element.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
        } else {
            element.setAccessibilityFrameInParentSpace(frame)
        }
    }

    /// The gutter-space rect of a 1-based line — full gutter width, the line
    /// fragment's own height. nil when the line has no layout yet.
    private func lineFrame(forLine line: Int) -> NSRect? {
        guard let textView, let layoutManager = textView.layoutManager,
              line >= 1, line <= lineStarts.count else { return nil }
        let text = textView.string as NSString
        let charIndex = min(lineStarts[line - 1], text.length)
        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        guard let y = gutterY(forTextContainerRect: fragment) else { return nil }
        return NSRect(x: 0, y: y, width: max(bounds.width, desiredWidth), height: fragment.height)
    }

    /// The gutter-space rect of a segment's run button — the same 16 pt disc
    /// `drawRunButton` paints over the top of the segment's bar.
    private func runButtonFrame(forLine line: Int) -> NSRect? {
        guard let lineFrame = lineFrame(forLine: line) else { return nil }
        let barX = desiredWidth - metrics.segmentBarGap / 2 - metrics.segmentBarWidth
        let size: CGFloat = 16
        // The painted disc overhangs the gutter's trailing edge by a couple of
        // points and is clipped there. The accessibility frame is the box
        // VoiceOver draws its cursor around, so keep it to what is on screen.
        let gutterWidth = max(bounds.width, desiredWidth)
        let x = min(barX + metrics.segmentBarWidth / 2 - size / 2, gutterWidth - size)
        return NSRect(x: max(0, x), y: lineFrame.origin.y + 1, width: size, height: size)
    }
}
