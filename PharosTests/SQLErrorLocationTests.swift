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

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
