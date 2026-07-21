import Foundation

/// Detects destructive keywords (DROP, DELETE, TRUNCATE) in SQL so the editor
/// can confirm before running, mirroring the schema browser's guard.
/// Uses the shared SQLLexer state map so keywords inside string literals,
/// comments, quoted identifiers, and dollar-quoted bodies never match.
/// Scans everywhere in normal-state text (not just the statement head) so
/// data-modifying CTEs like `WITH d AS (DELETE ...) SELECT ...` are caught;
/// the cost is a rare needless confirmation, never a missed one.
enum DestructiveSQLScanner {

    private static let destructiveKeywords: Set<String> = ["DROP", "DELETE", "TRUNCATE"]

    /// Returns the destructive keywords present in `sql`, uppercased, in first-seen
    /// order. Empty when the SQL contains none.
    static func destructiveKeywords(in sql: String) -> [String] {
        guard !sql.isEmpty else { return [] }

        let chars = Array(sql.utf16)
        let length = chars.count
        let stateMap = SQLLexer.buildStateMap(chars: chars, length: length)

        var found: [String] = []
        var word = ""
        var i = 0

        func flushWord() {
            if destructiveKeywords.contains(word), !found.contains(word) {
                found.append(word)
            }
            word = ""
        }

        while i < length {
            let ch = chars[i]
            if stateMap[i].isNormal, isWordChar(ch) {
                if let scalar = Unicode.Scalar(ch) {
                    word.append(Character(scalar).uppercased())
                }
            } else {
                flushWord()
            }
            i += 1
        }
        flushWord()

        return found
    }

    private static func isWordChar(_ ch: unichar) -> Bool {
        (ch >= 0x30 && ch <= 0x39)      // 0-9
            || (ch >= 0x41 && ch <= 0x5A)  // A-Z
            || (ch >= 0x61 && ch <= 0x7A)  // a-z
            || ch == 0x5F                  // _
    }
}
