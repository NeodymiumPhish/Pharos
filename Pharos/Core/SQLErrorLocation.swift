import Foundation

/// Where a PostgreSQL error points inside the SQL that produced it.
///
/// Two paths in the app carry that position in two different shapes, so this
/// type has two entry points:
/// - Execute: the position is inside the message text, because pharos-core's
///   `format_db_error` appends `at character N`. Use `parse(from:)`.
/// - Live validation: the position arrives as its own field and the message
///   holds no suffix. Use `tokenLength(from:)` with `init(charPosition:tokenLength:)`.
struct SQLErrorLocation: Equatable {

    /// 1-based character offset, exactly as PostgreSQL reports it.
    let charPosition: Int

    /// Length of the token named by `near "…"`, or 0 when the message names none.
    let tokenLength: Int

    init(charPosition: Int, tokenLength: Int) {
        self.charPosition = charPosition
        self.tokenLength = tokenLength
    }

    private static let positionRegex = try! NSRegularExpression(pattern: #"at character (\d+)"#)
    private static let nearTokenRegex = try! NSRegularExpression(pattern: #"near "([^"]+)""#)

    /// Read the position out of the message text. Returns nil when the message
    /// carries none, which is every error that is not about a place in the SQL.
    static func parse(from message: String) -> SQLErrorLocation? {
        let ns = message as NSString
        let all = NSRange(location: 0, length: ns.length)
        // The LAST match, not the first: pharos-core appends the real position at
        // the end (it uses `rfind` for this same reason), and the message before
        // it can quote SQL that holds the same words.
        guard let match = positionRegex.matches(in: message, range: all).last,
              match.numberOfRanges > 1,
              let position = Int(ns.substring(with: match.range(at: 1)))
        else { return nil }
        return SQLErrorLocation(charPosition: position, tokenLength: tokenLength(from: message))
    }

    /// Length of the token in `near "…"`, or 0 when the message names none.
    static func tokenLength(from message: String) -> Int {
        let ns = message as NSString
        guard let match = nearTokenRegex.firstMatch(
            in: message, range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges > 1 else { return 0 }
        return match.range(at: 1).length
    }

    /// The same range, moved from `sql` into the editor document `text`.
    ///
    /// A failure carries the substituted segment that ran, not the whole
    /// document, so a position that counts into the segment cannot mark the
    /// editor until it is moved. The move is a search for the segment inside the
    /// document, and it gives nil in every case where the answer would be a
    /// guess:
    /// - the segment is not in the document, because `{{variable}}` substitution
    ///   changed its length or the user has edited since the run
    /// - the segment is in the document twice, so the run could have been either
    ///
    /// Nil means the caller marks nothing. A wrong caret is worse than no caret.
    func range(of sql: String, in text: String) -> NSRange? {
        guard let local = range(in: sql) else { return nil }
        // The common case is a direct run, where the two texts are the same.
        if text == sql { return local }

        let ns = text as NSString
        let found = ns.range(of: sql)
        guard found.location != NSNotFound else { return nil }

        let afterFirst = NSRange(
            location: NSMaxRange(found), length: ns.length - NSMaxRange(found)
        )
        guard ns.range(of: sql, options: [], range: afterFirst).location == NSNotFound else {
            return nil
        }
        return NSRange(location: found.location + local.location, length: local.length)
    }

    /// The range to mark inside `sql`, or nil when the position falls outside it.
    /// With no token length the range runs to the end of the line, and it never
    /// holds the line ending.
    func range(in sql: String) -> NSRange? {
        let ns = sql as NSString
        let start = charPosition - 1        // PostgreSQL counts from 1
        guard start >= 0, start < ns.length else { return nil }

        if tokenLength > 0 {
            return NSRange(location: start, length: min(tokenLength, ns.length - start))
        }

        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        var end = line.location + line.length
        if end > start, ns.character(at: end - 1) == UInt16(UnicodeScalar("\n").value) { end -= 1 }
        if end > start, ns.character(at: end - 1) == UInt16(UnicodeScalar("\r").value) { end -= 1 }
        // At least one character, so a position that lands on a line ending still
        // marks something. This matches the behaviour of the code being replaced.
        return NSRange(location: start, length: max(1, end - start))
    }
}
