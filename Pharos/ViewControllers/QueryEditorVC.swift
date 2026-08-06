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
    private var foldRegionTask: Task<Void, Never>?
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

        // Re-apply settings when they change. Dedup the publisher so unrelated
        // republishes (the AppSettings struct is shared across UI surfaces) do
        // not trigger a full editor rebuild + rehighlight pass.
        stateManager.$settings
            .removeDuplicates()
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
        // Format off main — sqlformat can chew tens of ms on large queries.
        // Bail if the editor text changed under us (user kept typing) so we
        // don't clobber their work with a stale formatted copy.
        Task { @MainActor [weak self] in
            let formatted = await PharosCore.formatSQL(current)
            guard let self, self.getSQL() == current else { return }
            self.setSQL(formatted)
            self.textDidChange(formatted)
        }
    }

    /// Flag to suppress the onTextChange callback during programmatic text updates.
    private var suppressTextChange = false

    func setSQL(_ sql: String) {
        // Programmatic replacement bypasses didChangeText — kill any pending
        // list-paste offer explicitly so it can't survive into new content.
        textView.invalidateListPasteOffer()
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

    /// Set the variable names used for `{{token}}` highlighting.
    func setVariableNames(_ names: Set<String>) {
        textView.variableNames = names
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

    /// Mark an error at `range` in the document: a dot in the gutter and a red
    /// underline on the faulty text.
    ///
    /// The range is in document coordinates, not in the coordinates of the SQL
    /// that produced the error. Those two differ whenever the user runs one
    /// segment out of a longer document, or whenever `{{variable}}` substitution
    /// changed the text — so the caller does the move, with
    /// `SQLErrorLocation.range(of:in:)`.
    func markError(range: NSRange) {
        let text = textView.string
        guard NSMaxRange(range) <= (text as NSString).length else { return }
        // +1 because lineNumber counts to a 1-based position, which is the form
        // PostgreSQL reports and the form this code has always been given.
        gutter?.setErrorLines([lineNumber(forCharacterIndex: range.location + 1, in: text)])
        textView.addErrorUnderline(range: range)
    }

    /// Mark an error whose position counts into the whole document. Live
    /// validation runs on the document text, so it takes this path.
    func markError(_ location: SQLErrorLocation) {
        guard let range = location.range(in: textView.string) else { return }
        markError(range: range)
    }

    /// Put the caret on `range`, scroll it into sight and take focus. Used by the
    /// error sheet's Go to Error button, with a document range.
    func revealError(range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(textView)
    }

    /// Clear all error markers (gutter dots + underlines).
    func clearErrorMarkers() {
        gutter?.clearErrors()
        textView.clearErrorUnderlines()
    }

    // MARK: - Settings

    /// Signature of the settings fields that actually affect the editor's
    /// visible glyph layout. We only rehighlight when this changes — toggling
    /// unrelated settings (nullDisplay, boolDisplay, etc.) leaves the
    /// glyph-level layout untouched and shouldn't pay for a full document
    /// repaint × tab count.
    private struct EditorSignature: Equatable {
        let fontFamily: String
        let fontSize: UInt32
        let tabSize: UInt32
        let wordWrap: Bool
        let lineNumbers: Bool
    }

    private var lastAppliedSignature: EditorSignature?

    private func applySettings() {
        let editor = stateManager.settings.editor
        let signature = EditorSignature(
            fontFamily: editor.fontFamily,
            fontSize: editor.fontSize,
            tabSize: editor.tabSize,
            wordWrap: editor.wordWrap,
            lineNumbers: editor.lineNumbers
        )
        guard signature != lastAppliedSignature else { return }
        let needsRehighlight = signature.fontFamily != lastAppliedSignature?.fontFamily
            || signature.fontSize != lastAppliedSignature?.fontSize
            || signature.tabSize != lastAppliedSignature?.tabSize
            || signature.wordWrap != lastAppliedSignature?.wordWrap
        lastAppliedSignature = signature

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
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.size.width = CGFloat.greatestFiniteMagnitude
            textView.isHorizontallyResizable = true
        }

        if needsRehighlight {
            textView.highlightSyntax()
        }
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

    /// Forward the tab's running-segment indices to the gutter. Pass empty set to stop pulsing.
    func setRunningSegmentIndices(_ indices: Set<Int>) {
        gutter?.setRunningSegmentIndices(indices)
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

        // Debounced fold region recalculation (full document parse — not needed per keystroke)
        foldRegionTask?.cancel()
        foldRegionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            guard !Task.isCancelled, let self else { return }
            self.recalculateFoldRegions()
        }

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

        // Skip live validation while unsubstituted variable tokens are present:
        // Postgres would flag `{{...}}` as a syntax error, and substituted-text
        // error offsets wouldn't map back to the editor's token-form text.
        guard !VariableSubstitutor.containsTokens(sql) else {
            await MainActor.run { self.clearErrorMarkers() }
            return
        }

        do {
            let result = try await PharosCore.validateSQL(connectionId: connectionId, sql: sql)
            await MainActor.run {
                if let error = result.error, let position = error.position {
                    self.markError(SQLErrorLocation(
                        charPosition: position,
                        tokenLength: SQLErrorLocation.tokenLength(from: error.message)
                    ))
                } else {
                    self.clearErrorMarkers()
                }
            }
        } catch {
            // Validation failure is non-critical, just clear markers
            await MainActor.run { self.clearErrorMarkers() }
        }
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
