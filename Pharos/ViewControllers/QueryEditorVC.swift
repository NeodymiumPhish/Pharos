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

    /// The tab ID this editor is associated with.
    var tabId: String?

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
        gutter = gutterView

        container.addSubview(gutterView)
        container.addSubview(scrollView)

        // Autocomplete
        completionProvider.attachTo(textView)
        textView.completionDelegate = self

        // Text change handler — sync back to tab state and validate
        textView.onTextChange = { [weak self] newText in
            self?.textDidChange(newText)
        }

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
        let current = getSQL()
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let formatted = PharosCore.formatSQL(current)
        setSQL(formatted)
        textDidChange(formatted)
    }

    func setSQL(_ sql: String) {
        textView.string = sql
        textView.highlightSyntax()
        gutter?.invalidateLineNumbers()
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

    // MARK: - Text Changes

    private func textDidChange(_ newText: String) {
        guard let tabId else { return }

        // Clear any execution error markers when user starts typing
        clearErrorMarkers()

        stateManager.updateTab(id: tabId) { tab in
            tab.sql = newText
            tab.isDirty = true
        }

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
            await MainActor.run { self.gutter?.clearErrors() }
            return
        }

        do {
            let result = try await PharosCore.validateSQL(connectionId: connectionId, sql: sql)
            await MainActor.run {
                if let error = result.error, let position = error.position {
                    // Convert character position to line number
                    let line = lineNumber(forCharacterIndex: position, in: sql)
                    self.gutter?.setErrorLines([line])
                } else {
                    self.gutter?.clearErrors()
                }
            }
        } catch {
            // Validation failure is non-critical, just clear markers
            await MainActor.run { self.gutter?.clearErrors() }
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
