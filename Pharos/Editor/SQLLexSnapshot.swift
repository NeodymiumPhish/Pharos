import Foundation

/// Everything the editor's parsers derive from one text before they do their
/// own work: the UTF-16 units, the per-unit lex state, and the line starts.
///
/// Three passes run after every edit — segments (100 ms), highlighting
/// (150 ms, off main), folds (200 ms) — and each used to build all of this
/// again from the same string: three `Array(text.utf16)`, three
/// `SQLLexer.buildStateMap`. The first pass after an edit builds the snapshot;
/// the other two find it in the cache. The cache is keyed by the text itself,
/// so a stale entry can never be served for different text, and it is
/// lock-guarded because the highlighter asks from a detached task.
///
/// The cache holds several texts, least recently used first out. With query
/// cards, every card's editor runs the same three passes on its own text, and
/// a one-entry cache would make each card's pass evict the others'.
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

    /// Most texts the cache holds at once: more than the cards on screen at a
    /// time, whose passes interleave.
    static let cacheCapacity = 16
    /// Most UTF-16 units the cache holds in all. A snapshot costs about 4 bytes
    /// of lex state and 2 of text per unit, so this caps it near 24 MB. The
    /// newest entry is kept even when it alone is over the limit.
    static let maxCachedLength = 4_000_000

    private static let lock = NSLock()
    /// Most recently used last.
    nonisolated(unsafe) private static var entries: [(hash: Int, snapshot: SQLLexSnapshot)] = []

    /// The snapshot for `text`, built if no cached one is for the same text.
    static func shared(for text: String) -> SQLLexSnapshot {
        // Hash outside the lock, and compare the full text only on a hash
        // match: a miss then costs one pass over `text`, not one per entry.
        let hash = text.hashValue
        lock.lock()
        if let i = entries.lastIndex(where: { $0.hash == hash && $0.snapshot.text == text }) {
            let hit = entries.remove(at: i)
            entries.append(hit)
            lock.unlock()
            return hit.snapshot
        }
        lock.unlock()
        // Build outside the lock: a long text lexes for milliseconds, and the
        // parsers must not serialise on it. Two racing builders of the same
        // text both produce a correct snapshot; the later store wins.
        let built = SQLLexSnapshot(text: text)
        lock.lock()
        entries.removeAll { $0.hash == hash && $0.snapshot.text == text }
        entries.append((hash, built))
        var total = entries.reduce(0) { $0 + $1.snapshot.length }
        while entries.count > 1 && (entries.count > cacheCapacity || total > maxCachedLength) {
            total -= entries.removeFirst().snapshot.length
        }
        lock.unlock()
        return built
    }

    /// How many texts the cache holds. For tests.
    static var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Empty the cache. For tests.
    static func clearCache() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
