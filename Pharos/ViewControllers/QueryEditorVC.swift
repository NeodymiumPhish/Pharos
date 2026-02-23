import AppKit
import Combine

/// Manages the SQL editor text view with line numbers, syntax highlighting,
/// and query execution. One instance per tab, swapped by ContentViewController.
class QueryEditorVC: NSViewController {

    let textView = SQLTextView()
    private var scrollView: NSScrollView!
    private var gutter: LineNumberGutter!
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var validationTask: Task<Void, Never>?

    /// The tab ID this editor is associated with.
    var tabId: String?

    /// Called when the user presses Cmd+Enter.
    var onExecute: ((String) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        self.view = container

        // Scroll view for text editor — uses autoresizing masks since parent
        // (NSSplitView) manages layout via frames, not Auto Layout
        scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
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

        // Line number gutter
        scrollView.hasVerticalRuler = true
        gutter = LineNumberGutter(textView: textView)
        scrollView.verticalRulerView = gutter
        scrollView.rulersVisible = true

        container.addSubview(scrollView)

        // Text change handler — sync back to tab state and validate
        textView.onTextChange = { [weak self] newText in
            self?.textDidChange(newText)
        }

        applySettings()
    }

    // MARK: - Public API

    func setSQL(_ sql: String) {
        textView.string = sql
        textView.highlightSyntax()
    }

    func getSQL() -> String {
        textView.string
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func setErrorLine(_ line: Int?) {
        if let line {
            gutter.setErrorLines([line])
        } else {
            gutter.clearErrors()
        }
    }

    // MARK: - Settings

    private func applySettings() {
        let editor = stateManager.settings.editor
        let fontName = editor.fontFamily.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Menlo"
        let fontSize = CGFloat(editor.fontSize)

        if let font = NSFont(name: fontName, size: fontSize) {
            textView.font = font
        } else {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    // MARK: - Text Changes

    private func textDidChange(_ newText: String) {
        guard let tabId else { return }

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
            await MainActor.run { gutter.clearErrors() }
            return
        }

        do {
            let result = try await PharosCore.validateSQL(connectionId: connectionId, sql: sql)
            await MainActor.run {
                if let error = result.error, let position = error.position {
                    // Convert character position to line number
                    let line = lineNumber(forCharacterIndex: position, in: sql)
                    gutter.setErrorLines([line])
                } else {
                    gutter.clearErrors()
                }
            }
        } catch {
            // Validation failure is non-critical, just clear markers
            await MainActor.run { gutter.clearErrors() }
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
