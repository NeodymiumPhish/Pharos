import Foundation

/// Everything the editor's parsers derive from one text before they do their
/// own work: the UTF-16 units, the per-unit lex state, and the line starts.
///
/// Three passes run after every edit — segments (100 ms), highlighting
/// (150 ms, off main), folds (200 ms) — and each used to build all of this
/// again from the same string: three `Array(text.utf16)`, three
/// `SQLLexer.buildStateMap`. The first pass after an edit builds the snapshot;
/// the other two find it in the one-entry cache. The cache is keyed by the
/// text itself, so a stale entry can never be served for different text, and
/// it is lock-guarded because the highlighter asks from a detached task.
///
/// Pure Foundation, immutable once built: safe to hand across threads.
final class SQLLexSnapshot: @unchecked Sendable {
    let text: String
    let chars: [unichar]
    let length: Int
    /// Lex state at every UTF-16 position — the one source of truth for what
    /// is inside a string, a comment or a dollar quote.
    let stateMap: [SQLLexState]
    /// 0-based UTF-16 offset at which each 1-based line begins; `[0]` for
    /// line 1. A text with N newlines has N + 1 entries.
    let lineStarts: [Int]

    init(text: String) {
        self.text = text
        let chars = Array(text.utf16)
        self.chars = chars
        self.length = chars.count
        self.stateMap = SQLLexer.buildStateMap(chars: chars, length: chars.count)
        var starts = [0]
        starts.reserveCapacity(chars.count / 40 + 1)
        for (i, ch) in chars.enumerated() where ch == 0x0A {
            starts.append(i + 1)
        }
        self.lineStarts = starts
    }

    // MARK: - Shared cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SQLLexSnapshot?

    /// The snapshot for `text`, built if the cached one is for other text.
    static func shared(for text: String) -> SQLLexSnapshot {
        lock.lock()
        if let cached, cached.text == text {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // Build outside the lock: a long text lexes for milliseconds, and the
        // parsers must not serialise on it. Two racing builders of the same
        // text both produce a correct snapshot; the later store wins.
        let built = SQLLexSnapshot(text: text)
        lock.lock()
        cached = built
        lock.unlock()
        return built
    }
}
