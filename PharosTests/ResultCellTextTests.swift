import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    func r(_ v: AnyCodable, _ c: PGTypeCategory) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗", nullString: "NULL")
    }
    expect(r(AnyCodable("t"), .boolean) == "✓", "bool t → true glyph")
    expect(r(AnyCodable("true"), .boolean) == "✓", "bool true → true glyph")
    expect(r(AnyCodable("F"), .boolean) == "✗", "bool F → false glyph (case-insensitive)")
    expect(r(AnyCodable("false"), .boolean) == "✗", "bool false → false glyph")
    expect(r(AnyCodable("maybe"), .boolean) == "maybe", "unknown bool → raw")
    expect(r(AnyCodable(nil), .string) == "NULL", "null → null string")
    expect(r(AnyCodable("a\nb"), .string) == "a↵b", "string newline flattened")
    expect(r(AnyCodable("{\n}"), .json) == "{↵}", "json newline flattened")
    expect(r(AnyCodable("42"), .numeric) == "42", "numeric raw")
    expect(r(AnyCodable("2026-01-01"), .temporal) == "2026-01-01", "temporal raw")

    // MARK: - Hostile scalars are escaped for DISPLAY

    // The grid draws attacker-controlled data. `DisplayEscape` owns the rule;
    // these pin that the grid's render boundary actually applies it, per
    // category — a branch that forgot the call is the realistic defect.
    expect(r(AnyCodable("safe\u{202E}gpj.exe"), .string) == "safe<U+202E>gpj.exe",
           "string: a bidi override is shown, not obeyed")
    expect(r(AnyCodable("10.0.0.1\u{200B}"), .string) == "10.0.0.1<U+200B>",
           "string: a zero-width space cannot hide in a cell")
    expect(r(AnyCodable("10.0.0.1 "), .string) == "10.0.0.1<U+0020>",
           "string: a trailing space is marked, so look-alikes differ")
    expect(r(AnyCodable("a\u{0000}b"), .string) == "a<U+0000>b",
           "string: NUL no longer reaches the label")
    expect(r(AnyCodable("{\u{202E}}"), .json) == "{<U+202E>}", "json: escaped too")
    expect(r(AnyCodable("{a,\u{200B}b}"), .array) == "{a,<U+200B>b}", "array: escaped too")
    expect(r(AnyCodable("1\u{202E}2"), .numeric) == "1<U+202E>2",
           "numeric: the category is inferred from the column type, not a guarantee")
    expect(r(AnyCodable("2026\u{200B}-01-01"), .temporal) == "2026<U+200B>-01-01",
           "temporal: same")
    expect(r(AnyCodable("m\u{202E}aybe"), .boolean) == "m<U+202E>aybe",
           "boolean: a non-keyword value in a bool column is data, and is escaped")

    // Flattening runs BEFORE escaping, so a newline keeps its readable ↵ marker
    // rather than becoming <U+000A>. Pinned because the order is the whole point.
    expect(r(AnyCodable("a\nb"), .json) == "a↵b", "newline stays ↵, it does not become <U+000A>")

    // MARK: - Ordinary data is NOT mangled

    expect(r(AnyCodable("café ☕ 日本"), .string) == "café ☕ 日本", "accents, emoji and CJK untouched")
    expect(r(AnyCodable("CN=evil corp, O=x"), .string) == "CN=evil corp, O=x",
           "interior spaces untouched")
    expect(r(AnyCodable("t"), .boolean) == "✓", "the bool keywords still short-circuit")
    expect(r(AnyCodable(nil), .string) == "NULL", "the NULL string is app-owned and unescaped")

    // MARK: - Maximum characters per cell (Settings ▸ Results ▸ Cells)

    // Display only, like everything else here: copy, export, find and sort
    // read the raw value and never come through this type.
    func rMax(_ v: AnyCodable, _ c: PGTypeCategory, _ limit: UInt32) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗",
                                nullString: "NULL", maximumCharacters: limit)
    }

    expect(rMax(AnyCodable("abcdefghij"), .string, 0) == "abcdefghij",
           "limit 0 is no limit")
    expect(rMax(AnyCodable("abcde"), .string, 5) == "abcde",
           "a value exactly at the limit is untouched — no ellipsis for nothing removed")
    expect(rMax(AnyCodable("abc"), .string, 5) == "abc",
           "a value shorter than the limit is untouched")
    expect(rMax(AnyCodable("abcdefghij"), .string, 5) == "abcde…",
           "a longer value is cut at the limit and gains an ellipsis")
    expect(rMax(AnyCodable("abcdefghij"), .string, 1) == "a…", "a limit of 1 still works")
    expect(rMax(AnyCodable("123456789"), .numeric, 4) == "1234…", "numeric is truncated too")
    expect(rMax(AnyCodable("2026-01-01 00:00:00"), .temporal, 10) == "2026-01-01…",
           "temporal is truncated too")
    expect(rMax(AnyCodable("maybe not"), .boolean, 5) == "maybe…",
           "a non-keyword value in a bool column is truncated")

    // The limit counts Characters, not UTF-8 bytes and not UTF-16 units. Four
    // accented letters are four characters (7 UTF-8 bytes), and four emoji are
    // four characters (16 UTF-8 bytes, 8 UTF-16 units).
    expect(rMax(AnyCodable("éàüñ!"), .string, 4) == "éàüñ…",
           "the limit counts Characters, not UTF-8 bytes (accents)")
    expect(rMax(AnyCodable("日本語です!"), .string, 3) == "日本語…",
           "the limit counts Characters, not UTF-8 bytes (CJK)")
    expect(rMax(AnyCodable("☕☕☕☕☕"), .string, 4) == "☕☕☕☕…",
           "the limit counts Characters, not UTF-16 units (emoji)")
    // A flag is one Character made of two scalars; cutting it in half would
    // produce a different glyph, which is exactly what `prefix` prevents.
    expect(rMax(AnyCodable("🇬🇧🇬🇧🇬🇧"), .string, 2) == "🇬🇧🇬🇧…",
           "a multi-scalar grapheme is one Character and is never split")

    // The app's OWN display tokens are not data and are never cut: a "NUL…"
    // where a NULL was would be the app misreporting itself.
    expect(rMax(AnyCodable(nil), .string, 2) == "NULL", "the NULL string is never truncated")
    expect(rMax(AnyCodable("true"), .boolean, 0) == "✓", "the bool keywords are never truncated")

    // Escaping runs BEFORE truncation, because the limit is a limit on what is
    // DRAWN and `<U+202E>` is eight drawn characters where the scalar was one.
    expect(rMax(AnyCodable("\u{202E}abcdefgh"), .string, 4) == "<U+2…",
           "the limit applies to the escaped text, which is the text on screen")

    // MARK: - Escaping can be turned off (Settings ▸ Results ▸ Cells)

    func rRaw(_ v: AnyCodable, _ c: PGTypeCategory) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗",
                                nullString: "NULL", escapeControls: false)
    }
    expect(rRaw(AnyCodable("safe\u{202E}gpj.exe"), .string) == "safe\u{202E}gpj.exe",
           "escaping off passes the scalar through")
    // Flattening is NOT escaping: a label that silently becomes two lines is a
    // layout fault, so `↵` stays whatever the setting says.
    expect(rRaw(AnyCodable("a\nb"), .string) == "a↵b", "escaping off still flattens newlines")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
