import Foundation

// Tests for `GeneratedTextPolicy`, run by
// scripts/test-generated-text-policy.sh.

private var failures = 0
private var passes = 0

private func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    expect(a == b, "\(message)\n    got:      \(a)\n    expected: \(b)", line: line)
}

private func testProseIsLeftAloneWhenItIsFine() {
    let sentence = "The column \"amount\" does not exist in sales.orders."
    expectEqual(GeneratedTextPolicy.prose(sentence, limit: 400), sentence, "an ordinary sentence is unchanged")
    expectEqual(GeneratedTextPolicy.prose("Größe ist 数量 — naïve", limit: 400), "Größe ist 数量 — naïve", "other scripts and punctuation are kept")
    expectEqual(GeneratedTextPolicy.prose(nil, limit: 400), "", "nothing is nothing")
    expectEqual(GeneratedTextPolicy.prose("   ", limit: 400), "", "only spaces is nothing")
}

private func testProseIsOneParagraph() {
    expectEqual(GeneratedTextPolicy.prose("  one\n\ntwo\tthree   four \r\n", limit: 400), "one two three four",
                "line breaks, tabs and runs of spaces become one space")
    expectEqual(GeneratedTextPolicy.prose("a\u{00A0}b\u{2028}c", limit: 400), "a b c", "odd spaces and separators too")
}

private func testProseCannotMisrepresentItself() {
    expectEqual(GeneratedTextPolicy.prose("safe\u{202E}gpj.exe", limit: 400), "safegpj.exe", "a bidi override is removed")
    expectEqual(GeneratedTextPolicy.prose("\u{2066}DROP\u{2069} nothing", limit: 400), "DROP nothing", "isolates are removed")
    expectEqual(GeneratedTextPolicy.prose("ord\u{200B}ers\u{FEFF}", limit: 400), "orders", "zero-width characters are removed")
    expectEqual(GeneratedTextPolicy.prose("bell\u{07} and escape\u{1B}[31m", limit: 400), "bell and escape[31m", "control characters are removed")
}

private func testProseIsCapped() {
    let long = Array(repeating: "word", count: 300).joined(separator: " ")
    let capped = GeneratedTextPolicy.prose(long, limit: 100)
    expect(capped.count <= 101, "at most the limit and an ellipsis, got \(capped.count)")
    expect(capped.hasSuffix("word\u{2026}"), "cut at a whole word, with an ellipsis: …\(capped.suffix(12))")
    expect(!capped.hasSuffix(" \u{2026}"), "no space before the ellipsis")

    let unbroken = String(repeating: "x", count: 500)
    let hard = GeneratedTextPolicy.prose(unbroken, limit: 100)
    expectEqual(hard.count, 101, "text with no space to cut at is cut at the limit")

    let exact = String(repeating: "y", count: 100)
    expectEqual(GeneratedTextPolicy.prose(exact, limit: 100), exact, "text at the limit is not touched")

    let early = "a " + String(repeating: "z", count: 300)
    expect(GeneratedTextPolicy.prose(early, limit: 100).count > 50, "a space near the start does not throw most of it away")
}

private func testList() {
    let ten = (1...10).map { "fix \($0)" }
    expectEqual(GeneratedTextPolicy.list(ten, count: 3, limit: 400), ["fix 1", "fix 2", "fix 3"], "more than was asked for is cut to the count")
    expectEqual(GeneratedTextPolicy.list(["one", "two"], count: 3, limit: 400), ["one", "two"], "fewer is left alone")
    expectEqual(GeneratedTextPolicy.list(["", "  ", "\u{200B}", "real", "\n", "also real"], count: 3, limit: 400), ["real", "also real"],
                "empty items do not use up the count")
    expectEqual(GeneratedTextPolicy.list(nil, count: 3, limit: 400), [], "no list is an empty list")
    let long = GeneratedTextPolicy.list([String(repeating: "w ", count: 400)], count: 3, limit: 50)
    expect((long.first?.count ?? 0) <= 51, "each item is capped")
    expectEqual(GeneratedTextPolicy.fixLimit, 3, "an explanation is asked for at most three fixes")
}

private func testCode() {
    let sql = "SELECT id,\n\tname\r\nFROM sales.orders  -- two spaces kept\nWHERE name = 'a b'"
    expectEqual(GeneratedTextPolicy.code(sql), sql, "ordinary SQL keeps its line breaks, tabs and spacing")
    expectEqual(GeneratedTextPolicy.code("SELECT 'é', \"Größe\", '数量'"), "SELECT 'é', \"Größe\", '数量'", "other scripts are kept")
    expectEqual(GeneratedTextPolicy.code("SELECT 1 -- \u{202E}eteled\u{202C}\nFROM t"), "SELECT 1 -- eteled\nFROM t", "bidi controls are removed")
    expectEqual(GeneratedTextPolicy.code("FROM ord\u{200B}ers"), "FROM orders", "zero-width characters are removed")
    expectEqual(GeneratedTextPolicy.code("SELECT\u{00A0}1"), "SELECT 1", "a no-break space becomes a space")
    expectEqual(GeneratedTextPolicy.code("SELECT 1\u{2028}FROM t"), "SELECT 1 FROM t", "a line separator becomes a space")
    expectEqual(GeneratedTextPolicy.code("SELECT\u{00} 1\u{1B}"), "SELECT 1", "other controls are removed")
    let once = GeneratedTextPolicy.code("a\u{202E}b\u{00A0}c")
    expectEqual(GeneratedTextPolicy.code(once), once, "cleaning twice changes nothing more")
}

func runTests() {
    testProseIsLeftAloneWhenItIsFine()
    testProseIsOneParagraph()
    testProseCannotMisrepresentItself()
    testProseIsCapped()
    testList()
    testCode()
    print("\(passes) passed, \(failures) failed")
    if failures > 0 { exit(1) }
}
