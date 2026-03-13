import AppKit
import Combine

/// Manages the SQL editor text view with line numbers, syntax highlighting,
/// and query execution. One instance per tab, swapped by ContentViewController.
class QueryEditorVC: NSViewController {

    let textView = SQLTextView()
    let completionProvider = SQLCompletionProvider()
    private var scrollView: NSScrollView!
    private var gutter: LineNumberGutter?
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var validationTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var highlightOverlay: NSView?
    private var highlightFadeTask: Task<Void, Never>?

    /// The tab ID this editor is associated with.
    var tabId: String?

    /// Current parsed SQL segments.
    private(set) var segments: [SQLSegment] = []

    /// Current fold regions for code folding.
    private var foldRegions: [SQLFoldRegion] = []

    /// Callback fired when the user clicks the gutter run button on a segment.
    var onRunSegment: ((SQLSegment) -> Void)?

    /// Callback fired when editor text changes (for result tab staleness tracking).
    var onTextEdited: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        self.view = container

        // Scroll view for text editor — uses frame-based layout since parent
        // (NSSplitView) manages layout via frames, not Auto Layout.
        // Frame is set in viewDidLayout; starts at container bounds minus gutter.
        scrollView = NSScrollView(frame: container.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Configure text view sizing — NSScrollView manages its documentView
        // via frames, so do NOT set translatesAutoresizingMaskIntoConstraints = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        // Line number gutter — standalone NSView beside the scroll view,
        // outside the scroll view hierarchy to avoid macOS 26's ruler VEV injection.
        let gutterView = LineNumberGutter(textView: textView, scrollView: scrollView)
        gutterView.onWidthChange = { [weak self] in
            self?.view.needsLayout = true
        }
        gutterView.onRunSegment = { [weak self] segment in
            self?.onRunSegment?(segment)
        }
        gutterView.onToggleFold = { [weak self] regionIndex in
            self?.toggleFold(at: regionIndex)
        }
        gutter = gutterView

        container.addSubview(gutterView)
        container.addSubview(scrollView)

        // Autocomplete
        completionProvider.attachTo(textView)
        textView.completionDelegate = self

        // Text change handler — sync back to tab state and validate
        textView.onTextChange = { [weak self] newText in
            guard let self, !self.suppressTextChange else { return }
            self.textDidChange(newText)
        }

        // Fold state changed — re-sync gutter line numbers
        textView.onFoldStateChanged = { [weak self] in
            self?.gutter?.invalidateLineNumbers()
        }

        // Click on fold placeholder — unfold that region
        textView.onPlaceholderClicked = { [weak self] foldEntryId in
            guard let self else { return }
            self.textView.unfold(id: foldEntryId)
            self.recalculateFoldRegions()
        }

        // Track cursor movement for active segment highlighting
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )

        applySettings()

        // Re-apply settings when they change
        stateManager.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutGutterAndScrollView()
    }

    private func layoutGutterAndScrollView() {
        let bounds = view.bounds
        let gutterWidth: CGFloat
        if let gutter, !gutter.isHidden {
            gutterWidth = gutter.desiredWidth
            gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        } else {
            gutterWidth = 0
        }
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
    }

    // MARK: - Public API

    func formatSQL() {
        // Unfold all before formatting so we format the full original text
        textView.unfoldAll()
        let current = getSQL()
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let formatted = PharosCore.formatSQL(current)
        setSQL(formatted)
        textDidChange(formatted)
    }

    /// Flag to suppress the onTextChange callback during programmatic text updates.
    private var suppressTextChange = false

    func setSQL(_ sql: String) {
        // Suppress the onTextChange callback to avoid double-parsing:
        // setSQL already parses segments, and onTextChange would trigger
        // recalculateSegments which parses again.
        suppressTextChange = true
        textView.string = sql
        suppressTextChange = false
        textView.highlightSyntax()
        gutter?.invalidateLineNumbers()
        // Immediately recalculate segments for the new text
        segments = SQLSegmentParser.parse(sql)
        let cursor = textView.selectedRange().location
        let activeIndex = SQLSegmentParser.segmentIndex(forCursorAt: cursor, in: segments)
        gutter?.setSegments(segments, activeIndex: activeIndex)

        // Recalculate fold regions
        recalculateFoldRegions()
    }

    @objc private func editorSelectionDidChange(_: Notification) {
        updateActiveSegment()
    }

    func getSQL() -> String {
        textView.string
    }

    func getCursorPosition() -> Int {
        textView.selectedRange().location
    }

    func setCursorPosition(_ position: Int) {
        let text = textView.string as NSString
        let safePosn = min(position, text.length)
        textView.setSelectedRange(NSRange(location: safePosn, length: 0))
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func updateSchemaMetadata(
        schemas: [SchemaInfo],
        tables: [String: [TableInfo]],
        columnsByTable: [String: [ColumnInfo]]
    ) {
        completionProvider.schemas = schemas
        completionProvider.tables = tables
        completionProvider.columnsByTable = columnsByTable
    }

    // MARK: - Error Markers

    /// Mark an error at the given character position in the editor.
    /// Sets the gutter error dot and adds a red underline on the error token.
    /// - Parameters:
    ///   - charPosition: 1-based character offset from PostgreSQL's error position
    ///   - tokenLength: length of the error token to underline (0 = underline to end of line)
    func markError(charPosition: Int, tokenLength: Int) {
        let text = textView.string
        let nsText = text as NSString
        let pos0 = charPosition - 1 // Convert to 0-based
        guard pos0 >= 0, pos0 < nsText.length else { return }

        // Set gutter error dot
        let line = lineNumber(forCharacterIndex: charPosition, in: text)
        gutter?.setErrorLines([line])

        // Determine underline range
        let underlineLength: Int
        if tokenLength > 0 {
            underlineLength = min(tokenLength, nsText.length - pos0)
        } else {
            // Underline from position to end of line
            let lineRange = nsText.lineRange(for: NSRange(location: pos0, length: 0))
            let lineEnd = lineRange.location + lineRange.length
            // Trim trailing newline
            let effectiveEnd = (lineEnd > 0 && nsText.character(at: lineEnd - 1) == UInt16(UnicodeScalar("\n").value))
                ? lineEnd - 1 : lineEnd
            underlineLength = max(1, effectiveEnd - pos0)
        }

        textView.addErrorUnderline(range: NSRange(location: pos0, length: underlineLength))
    }

    /// Clear all error markers (gutter dots + underlines).
    func clearErrorMarkers() {
        gutter?.clearErrors()
        textView.clearErrorUnderlines()
    }

    // MARK: - Settings

    private func applySettings() {
        let editor = stateManager.settings.editor

        // Font
        let fontName = editor.fontFamily.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Menlo"
        let fontSize = CGFloat(editor.fontSize)

        if fontName == "System Monospace" {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        } else if let font = NSFont(name: fontName, size: fontSize) {
            textView.font = font
        } else {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        // Tab size
        textView.tabSize = Int(editor.tabSize)

        // Line numbers — toggle gutter visibility and re-layout
        gutter?.isHidden = !editor.lineNumbers
        layoutGutterAndScrollView()

        // Word wrap
        if editor.wordWrap {
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size.width = textView.enclosingScrollView?.contentSize.width ?? 0
            textView.isHorizontallyResizable = false
        } else {
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
        }

        textView.highlightSyntax()
    }

    // MARK: - Segment API

    /// Returns the SQL segment at the current cursor position, or nil if none.
    func getSegmentSQLAtCursor() -> SQLSegment? {
        let cursor = textView.selectedRange().location
        guard let idx = SQLSegmentParser.segmentIndex(forCursorAt: cursor, in: segments),
              idx < segments.count else { return nil }

        // Text storage always contains the full SQL (folds are display-layer only),
        // so segments parsed from textView.string are always correct.
        return segments[idx]
    }

    /// Set the result color for a segment bar in the gutter.
    func setSegmentColor(_ color: NSColor?, forSegmentIndex index: Int) {
        gutter?.setSegmentColor(color, forSegmentIndex: index)
    }

    /// Clear all segment result colors in the gutter.
    func clearSegmentColors() {
        gutter?.clearSegmentColors()
    }

    /// Highlight a line range in the editor (scroll to visible + 3-second fade overlay).
    func highlightLines(_ range: ClosedRange<Int>) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        var charStart = 0
        var currentLine = 1
        // Advance to the start line
        while currentLine < range.lowerBound && charStart < text.length {
            if text.character(at: charStart) == 0x0A /* newline */ {
                currentLine += 1
            }
            charStart += 1
        }
        var charEnd = charStart
        // Advance to the end line
        while currentLine <= range.upperBound && charEnd < text.length {
            if text.character(at: charEnd) == 0x0A /* newline */ {
                currentLine += 1
            }
            charEnd += 1
        }
        let charRange = NSRange(location: charStart, length: charEnd - charStart)
        textView.scrollRangeToVisible(charRange)

        // Show a highlight overlay that lasts 3 seconds then fades out
        showHighlightOverlay(for: charRange)
    }

    private func showHighlightOverlay(for charRange: NSRange) {
        // Cancel any previous fade
        highlightFadeTask?.cancel()
        highlightOverlay?.removeFromSuperview()

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Get the bounding rect for the character range
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        // Adjust for text container inset
        let inset = textView.textContainerInset
        rect.origin.x = 0
        rect.origin.y += inset.height
        rect.size.width = textView.bounds.width

        let overlay = NSView(frame: rect)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        overlay.layer?.cornerRadius = 3
        textView.addSubview(overlay)
        highlightOverlay = overlay

        // Hold for 3 seconds, then fade out over 0.5 seconds
        highlightFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let overlay = self.highlightOverlay else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                overlay.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.highlightOverlay?.removeFromSuperview()
                self?.highlightOverlay = nil
            }
        }
    }

    /// Recalculate segments from the current editor text (debounced).
    private func recalculateSegments() {
        segmentTask?.cancel()
        segmentTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled, let self else { return }
            let text = self.textView.string
            self.segments = SQLSegmentParser.parse(text)
            let cursor = self.textView.selectedRange().location
            let activeIndex = SQLSegmentParser.segmentIndex(forCursorAt: cursor, in: self.segments)
            self.gutter?.setSegments(self.segments, activeIndex: activeIndex)
        }
    }

    /// Update the active segment highlight based on current cursor position (no debounce).
    private func updateActiveSegment() {
        let cursor = textView.selectedRange().location
        let activeIndex = SQLSegmentParser.segmentIndex(forCursorAt: cursor, in: segments)
        gutter?.setSegments(segments, activeIndex: activeIndex)
    }

    // MARK: - Code Folding

    /// Recalculate fold regions from the current editor text.
    private func recalculateFoldRegions() {
        foldRegions = rebuildFoldRegions()
        gutter?.setFoldRegions(foldRegions)
    }

    /// Re-parse fold regions from the full text and sync collapsed state from FoldState.
    /// Text storage is never modified for folding, so the parser always sees the full SQL.
    private func rebuildFoldRegions() -> [SQLFoldRegion] {
        var newRegions = SQLFoldingParser.parse(textView.string)
        let foldEntries = textView.foldState.entries

        // Mark regions as collapsed if FoldState has a matching entry
        for idx in 0..<newRegions.count {
            let region = newRegions[idx]
            // A fold entry matches a region if it starts near the region's fold start
            if let entry = foldEntries.first(where: { entry in
                let foldStart = entry.range.location
                return abs(foldStart - region.startCharIndex) <= 2
            }) {
                newRegions[idx].isCollapsed = true
                newRegions[idx].foldEntryId = entry.id
            }
        }

        return newRegions
    }

    /// Toggle fold/unfold for a region at the given index.
    private func toggleFold(at regionIndex: Int) {
        guard regionIndex >= 0, regionIndex < foldRegions.count else { return }

        let region = foldRegions[regionIndex]

        if region.isCollapsed {
            // Unfold: remove the fold entry from FoldState
            guard let entryId = region.foldEntryId else { return }
            textView.unfold(id: entryId)
        } else {
            // Fold: calculate the char range to fold
            let text = textView.string as NSString
            guard text.length > 0 else { return }

            let startCharIdx: Int
            let endCharIdx: Int

            switch region.kind {
            case .parenBlock, .subquery, .cte:
                // Fold only the inner content between ( and )
                startCharIdx = region.startCharIndex // char after '('
                endCharIdx = min(region.closeCharIndex - 1, text.length - 1) // char before ')'
            default:
                // Keyword-based folds: fold the full range
                startCharIdx = region.startCharIndex
                endCharIdx = min(region.endCharIndex, text.length - 1)
            }

            guard startCharIdx < text.length, startCharIdx <= endCharIdx else { return }

            let foldRange = NSRange(location: startCharIdx, length: endCharIdx - startCharIdx + 1)
            let lineCount = region.endLine - region.startLine
            let placeholder = " \u{25B8} \(lineCount) lines "

            textView.fold(range: foldRange, placeholder: placeholder)
        }

        // Rebuild fold regions to sync gutter state
        recalculateFoldRegions()
    }

    // MARK: - Text Changes

    private func textDidChange(_ newText: String) {
        guard let tabId else { return }

        // Clear any execution error markers when user starts typing
        clearErrorMarkers()

        // FoldState.adjustForEdit (called from SQLTextView.didChangeText) automatically
        // removes folds that overlap the edit and shifts folds after it.

        stateManager.updateTab(id: tabId) { tab in
            tab.sql = self.textView.string
            tab.isDirty = true
        }

        // Recalculate SQL segments
        recalculateSegments()

        // Recalculate fold regions
        recalculateFoldRegions()

        // Notify for result tab staleness
        onTextEdited?()

        // Debounced validation
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            await self?.validateSQL(newText)
        }
    }

    private func validateSQL(_ sql: String) async {
        guard let connectionId = stateManager.activeConnectionId,
              stateManager.status(for: connectionId) == .connected,
              !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run { self.clearErrorMarkers() }
            return
        }

        do {
            let result = try await PharosCore.validateSQL(connectionId: connectionId, sql: sql)
            await MainActor.run {
                if let error = result.error, let position = error.position {
                    let tokenLength = Self.parseTokenLength(from: error.message)
                    self.markError(charPosition: position, tokenLength: tokenLength)
                } else {
                    self.clearErrorMarkers()
                }
            }
        } catch {
            // Validation failure is non-critical, just clear markers
            await MainActor.run { self.clearErrorMarkers() }
        }
    }

    /// Extract token length from a PostgreSQL error message like `syntax error at or near "WHERE"`.
    /// Returns 0 if no token is found (caller falls back to underlining to end of line).
    private static let nearTokenRegex = try! NSRegularExpression(pattern: #"near "([^"]+)""#)

    static func parseTokenLength(from message: String) -> Int {
        let nsMessage = message as NSString
        guard let match = nearTokenRegex.firstMatch(
            in: message, range: NSRange(location: 0, length: nsMessage.length)
        ), match.numberOfRanges > 1 else {
            return 0
        }
        return match.range(at: 1).length
    }

    private func lineNumber(forCharacterIndex index: Int, in text: String) -> Int {
        var line = 1
        var pos = 0
        for char in text {
            if pos >= index { break }
            if char == "\n" { line += 1 }
            pos += 1
        }
        return line
    }
}

// MARK: - SQLTextViewCompletionDelegate

extension QueryEditorVC: SQLTextViewCompletionDelegate {

    var isCompletionShown: Bool { completionProvider.isShown }

    func triggerCompletion() {
        completionProvider.showCompletions(for: textView)
    }

    func updateCompletion() {
        completionProvider.showCompletions(for: textView)
    }

    func dismissCompletion() {
        completionProvider.dismiss()
    }

    func completionMoveUp() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.moveUp()
        return true
    }

    func completionMoveDown() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.moveDown()
        return true
    }

    func acceptCompletion() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.acceptSelected()
        return true
    }
}
