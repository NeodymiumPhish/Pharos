// Standalone test runner for SQLErrorLocation. Not part of the app target —
// compiled together with the implementation by scripts/test-sql-error-location.sh.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectRange(_ actual: NSRange?, _ expected: NSRange?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

func runTests() {
    // MARK: parse

    let syntax = "syntax error at or near \"WHERE\" at character 42"
    expectInt(SQLErrorLocation.parse(from: syntax)?.charPosition ?? -1, 42,
              "the parse reads the character position")
    expectInt(SQLErrorLocation.parse(from: syntax)?.tokenLength ?? -1, 5,
              "the parse reads the token length from near \"…\"")

    let noPosition = "relation \"users\" does not exist"
    expectTrue(SQLErrorLocation.parse(from: noPosition) == nil,
               "a message with no position gives nil")

    let positionNoToken = "column reference is ambiguous at character 17"
    expectInt(SQLErrorLocation.parse(from: positionNoToken)?.tokenLength ?? -1, 0,
              "a message with no near token gives token length 0")

    // pharos-core appends the real position last, and it uses rfind for the same
    // reason: the message can quote SQL that holds the same words.
    let twoPositions = "syntax error at or near \"at character 5\" at character 42"
    expectInt(SQLErrorLocation.parse(from: twoPositions)?.charPosition ?? -1, 42,
              "the parse takes the last position, not the first")

    // MARK: range

    let sql = "SELECT * FROM users\nWHERE"
    expectRange(SQLErrorLocation(charPosition: 21, tokenLength: 5).range(in: sql),
                NSRange(location: 20, length: 5),
                "a token range starts one character before the reported position")

    expectRange(SQLErrorLocation(charPosition: 21, tokenLength: 99).range(in: sql),
                NSRange(location: 20, length: 5),
                "a token longer than the text is cut at the end of the text")

    expectTrue(SQLErrorLocation(charPosition: 400, tokenLength: 3).range(in: sql) == nil,
               "a position past the end of the SQL gives nil")

    expectTrue(SQLErrorLocation(charPosition: 0, tokenLength: 3).range(in: sql) == nil,
               "a position of 0 gives nil, because PostgreSQL counts from 1")

    expectRange(SQLErrorLocation(charPosition: 8, tokenLength: 0).range(in: sql),
                NSRange(location: 7, length: 12),
                "with no token the range runs to the end of the line and holds no newline")

    expectRange(SQLErrorLocation(charPosition: 8, tokenLength: 0).range(in: "SELECT * FROM t\r\nx"),
                NSRange(location: 7, length: 8),
                "a CRLF line ending is not part of the range")

    // MARK: range(of:in:) — the segment-to-document move

    // A failure carries the segment that ran. When the user runs one statement out
    // of a longer document, the position counts into that segment only.
    let document = "SELECT 1;\n\nSELECT * FROM users WHERE;\n"
    let segment = "SELECT * FROM users WHERE;"
    let inSegment = SQLErrorLocation(charPosition: 21, tokenLength: 5)  // `WHERE`
    expectRange(inSegment.range(in: segment), NSRange(location: 20, length: 5),
                "inside the segment the token starts at index 20")
    expectRange(inSegment.range(of: segment, in: document), NSRange(location: 31, length: 5),
                "in the document the same token starts 11 characters later")

    expectRange(inSegment.range(of: segment, in: segment), NSRange(location: 20, length: 5),
                "a direct run, where document and segment are one text, needs no move")

    // Substitution changed the text, or the user edited after the run.
    expectTrue(inSegment.range(of: segment, in: "SELECT 1;\n") == nil,
               "a segment that is not in the document gives nil, so nothing is marked")

    // Two identical statements: which one ran is a guess, so refuse.
    expectTrue(inSegment.range(of: segment, in: segment + "\n" + segment) == nil,
               "a segment that appears twice gives nil rather than a guess")

    // The two entry points must agree. The live-validation path builds the
    // location from a separate position field and a message with no suffix.
    let viaParse = SQLErrorLocation.parse(from: syntax)!
    let viaInit = SQLErrorLocation(
        charPosition: 42,
        tokenLength: SQLErrorLocation.tokenLength(from: "syntax error at or near \"WHERE\"")
    )
    expectTrue(viaParse == viaInit, "both entry points build the same location")

    // MARK: code points versus UTF-16

    // PostgreSQL counts in code points; NSString indexes in UTF-16 units. One
    // astral character (2 UTF-16 units, 1 code point) before the error point
    // shifts the two counts apart by one unit per such character.

    // "😀SELECT * FROM users\nWHERE" — the emoji is 1 code point and 2 UTF-16
    // units. Without it, WHERE starts at code point 20 (0-based); with it,
    // WHERE starts at code point 21 (0-based), so charPosition is 22 (1-based).
    // In UTF-16 units the emoji costs 2, so WHERE starts at unit 22.
    let oneAstral = "\u{1F600}SELECT * FROM users\nWHERE"
    expectRange(SQLErrorLocation(charPosition: 22, tokenLength: 5).range(in: oneAstral),
                NSRange(location: 22, length: 5),
                "one astral character before the token shifts the UTF-16 start by one")

    // Two emojis: code point 22 (0-based) is where WHERE starts, so
    // charPosition 23. In UTF-16 units, the two emojis cost 4, so WHERE starts
    // at unit 24 — the shift adds up, one unit per astral character.
    let twoAstral = "\u{1F600}\u{1F600}SELECT * FROM users\nWHERE"
    expectRange(SQLErrorLocation(charPosition: 23, tokenLength: 5).range(in: twoAstral),
                NSRange(location: 24, length: 5),
                "two astral characters before the token shift the UTF-16 start by two")

    expectTrue(SQLErrorLocation(charPosition: 1, tokenLength: 0).range(in: "") == nil,
               "an empty SQL string gives nil for any position")

    // "SELECT" is 6 characters; position 6 (1-based) is the last one, 'T'.
    // With no trailing newline the range is 1 character long and its end is
    // the end of the text.
    expectRange(SQLErrorLocation(charPosition: 6, tokenLength: 0).range(in: "SELECT"),
                NSRange(location: 5, length: 1),
                "a position on the last character with no trailing newline gives a length-1 range at the end of the text")

    // "ababa" occurs in "abababa" at index 0 AND index 2 — an overlapping
    // second match that a search starting at the end of the first match would
    // miss. Either occurrence is a guess, so this must give nil.
    expectTrue(SQLErrorLocation(charPosition: 1, tokenLength: 1).range(of: "ababa", in: "abababa") == nil,
               "an overlapping second match still counts as appearing twice")

    // MARK: end of input

    // PostgreSQL's "at end of input" error reports a position one past the
    // last character — it ran out of text while it still needed more. Nothing
    // sits AT that offset, so the range must fall back to the last token.

    // The user's exact report: a trailing WHERE with no condition.
    // "SELECT\n  *\nFROM\n  conn\nWHERE" is 28 UTF-16 units long (counted by
    // hand: SELECT 0-5, \n 6, two spaces 7-8, * 9, \n 10, FROM 11-14, \n 15,
    // two spaces 16-17, conn 18-21, \n 22, WHERE 23-27). PostgreSQL reports
    // one past the last index, so charPosition is 29. WHERE starts at 23 and
    // is 5 characters long.
    let endOfInputSQL = "SELECT\n  *\nFROM\n  conn\nWHERE"
    let endOfInputMessage = "error returned from database: syntax error at end of input at character 29"
    expectInt(SQLErrorLocation.parse(from: endOfInputMessage)?.charPosition ?? -1, 29,
              "parse reads the character position out of an \"at end of input\" message")
    expectRange(SQLErrorLocation.parse(from: endOfInputMessage)?.range(in: endOfInputSQL),
                NSRange(location: 23, length: 5),
                "an end-of-input position with no token to mark falls back to the last token, WHERE")

    // The production shape, end to end. `runQuery` sends
    // `rendered.sql.trimmingCharacters(...)`, so the SQL that ran is the TRIMMED
    // text while the editor document usually keeps a trailing newline. The
    // position therefore has to survive both the end-of-input fallback and the
    // move into document coordinates. Document is 29 units, the sent text 28, and
    // WHERE sits at 23 in both because the trim only took the trailing newline.
    let editorDocument = "SELECT\n  *\nFROM\n  conn\nWHERE\n"
    let sentToServer = editorDocument.trimmingCharacters(in: .whitespacesAndNewlines)
    expectTrue(editorDocument != sentToServer, "the document and the sent SQL really do differ")
    expectRange(SQLErrorLocation.parse(from: endOfInputMessage)?
                    .range(of: sentToServer, in: editorDocument),
                NSRange(location: 23, length: 5),
                "an end-of-input mark reaches the editor document through the trim")

    // "SELECT * FROM t\n" is 16 characters; the last one is a newline. An
    // end-of-input position is 17 (one past 16). The newline is whitespace, so
    // the walk back lands on "t" at index 14, length 1.
    expectRange(SQLErrorLocation(charPosition: 17, tokenLength: 0).range(in: "SELECT * FROM t\n"),
                NSRange(location: 14, length: 1),
                "trailing whitespace after the last token is skipped; the mark lands on the token, not the newline")

    // "SELECT * FROM t," is 16 characters; the last one, a comma, is not a
    // word character, so it is marked alone rather than pulling in "t" before it.
    expectRange(SQLErrorLocation(charPosition: 17, tokenLength: 0).range(in: "SELECT * FROM t,"),
                NSRange(location: 15, length: 1),
                "a non-word last character is marked on its own, length 1")

    // "   \n  " holds no non-whitespace character at all, so even the
    // end-of-input fallback has nothing to mark.
    expectTrue(SQLErrorLocation(charPosition: 7, tokenLength: 0).range(in: "   \n  ") == nil,
               "a whitespace-only text gives nil even for an end-of-input position")

    // "SELECT" is 6 characters. One past the end (position 7) is the
    // end-of-input case, handled above; two past (position 8) has nothing to
    // fall back to — it is genuinely past the end, and must still give nil.
    expectTrue(SQLErrorLocation(charPosition: 8, tokenLength: 0).range(in: "SELECT") == nil,
               "a position more than one past the end of the SQL still gives nil")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
