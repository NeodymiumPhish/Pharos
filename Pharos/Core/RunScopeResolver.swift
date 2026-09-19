import Foundation

/// Decides what ⌘↩ runs, away from the view controller so it can be tested
/// without an editor, a connection or a window.
///
/// The caller passes what it has — the mode, the selected text, the segment
/// under the cursor and the whole buffer — and gets back either "run this
/// segment" (which keeps the gutter bar, the segment index and the line
/// range) or "run this text directly".
enum RunScopeResolver {

    /// One statement of the editor, as much of `SQLSegment` as this decision
    /// needs. Keeping it to these three fields is what lets the resolver be
    /// compiled and tested with no editor code behind it.
    struct Segment: Equatable {
        let index: Int
        let sql: String
        let lineRange: ClosedRange<Int>

        init(index: Int, sql: String, lineRange: ClosedRange<Int>) {
            self.index = index
            self.sql = sql
            self.lineRange = lineRange
        }
    }

    enum Resolution: Equatable {
        /// Run this parsed statement. The gutter can colour it.
        case segment(Segment)
        /// Run this text, which belongs to no single statement.
        case direct(sql: String)
        /// There is nothing to run.
        case nothing
    }

    /// - Parameters:
    ///   - mode: the user's choice.
    ///   - selectedText: the editor's selection, or nil when nothing is selected.
    ///   - segmentAtCursor: the statement the cursor is in, or nil when the
    ///     parser found none.
    ///   - fullText: everything in the editor.
    static func resolve(mode: RunScope,
                        selectedText: String?,
                        segmentAtCursor: Segment?,
                        fullText: String) -> Resolution {
        switch mode {
        case .statementAtCursor:
            if let segmentAtCursor { return .segment(segmentAtCursor) }
            return direct(fullText)

        case .selectionElseStatement:
            // A selection of nothing but whitespace is not a selection: it is
            // what a stray double-click on an empty line leaves behind, and
            // running it would do nothing while looking like a refusal.
            if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return direct(selectedText)
            }
            if let segmentAtCursor { return .segment(segmentAtCursor) }
            return direct(fullText)

        case .wholeBuffer:
            return direct(fullText)
        }
    }

    private static func direct(_ text: String) -> Resolution {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .nothing : .direct(sql: trimmed)
    }
}
