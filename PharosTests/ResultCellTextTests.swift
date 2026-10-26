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

    // MARK: - Tier A is disclosed for DISPLAY, whatever the setting says

    // The grid draws attacker-controlled data. `DisplayEscape` owns the rule;
    // these pin that the grid's render boundary actually applies it, per
    // category — a branch that forgot the call is the realistic defect. `r`
    // renders with the DEFAULT setting, which is now off.
    expect(r(AnyCodable("safe\u{202E}gpj.exe"), .string) == "safe<U+202E>gpj.exe",
           "string: a bidi override is shown, not obeyed")
    expect(r(AnyCodable("{\u{202E}}"), .json) == "{<U+202E>}", "json: escaped too")
    expect(r(AnyCodable("{a,\u{2066}b}"), .array) == "{a,<U+2066>b}", "array: escaped too")
    expect(r(AnyCodable("1\u{202E}2"), .numeric) == "1<U+202E>2",
           "numeric: the category is inferred from the column type, not a guarantee")
    expect(r(AnyCodable("2026\u{2028}-01-01"), .temporal) == "2026<U+2028>-01-01",
           "temporal: same")
    expect(r(AnyCodable("m\u{202E}aybe"), .boolean) == "m<U+202E>aybe",
           "boolean: a non-keyword value in a bool column is data, and is escaped")

    // MARK: - Tier B: raw by default, dimmed marks when the user asks

    func cell(_ v: AnyCodable, _ c: PGTypeCategory, on: Bool, limit: UInt32 = 0) -> DisplayEscape.CellText {
        ResultCellText.renderedCell(value: v, category: c, boolTrue: "✓", boolFalse: "✗",
                                    nullString: "NULL", maximumCharacters: limit, showInvisibles: on)
    }
    expect(r(AnyCodable(" abc "), .string) == " abc ", "default: edge spaces are drawn raw")
    expect(r(AnyCodable("10.0.0.1\u{200B}"), .string) == "10.0.0.1\u{200B}", "default: zero-width is drawn raw")
    expect(cell(AnyCodable("10.0.0.1 "), .string, on: true)
               == .init(text: "10.0.0.1\u{B7}", dimmedRanges: [NSRange(location: 8, length: 1)]),
           "on: a trailing space is a dimmed dot, so look-alikes differ")
    expect(cell(AnyCodable("a\u{0000}b"), .string, on: true)
               == .init(text: "a<U+0000>b", dimmedRanges: [NSRange(location: 1, length: 8)]),
           "on: NUL is named, dimmed")
    expect(cell(AnyCodable("{a,\u{200B}b}"), .array, on: true).text == "{a,<U+200B>b}", "on: array too")
    expect(cell(AnyCodable("2026\u{200B}-01-01"), .temporal, on: true).text == "2026<U+200B>-01-01",
           "on: temporal too")
    expect(cell(AnyCodable("m aybe "), .boolean, on: true).text == "m aybe\u{B7}", "on: boolean data too")
    expect(cell(AnyCodable("a\u{202E}b"), .string, on: true).dimmedRanges.isEmpty,
           "on: tier A is never dimmed")
    expect(cell(AnyCodable(nil), .string, on: true).dimmedRanges.isEmpty, "on: NULL is app text, no marks")
    // Truncation clips the ranges to what is still drawn.
    expect(cell(AnyCodable("ab   "), .string, on: true, limit: 3)
               == .init(text: "ab\u{B7}…", dimmedRanges: [NSRange(location: 2, length: 1)]),
           "on: a mark the ellipsis cuts through keeps only its drawn part")
    expect(cell(AnyCodable("abcdef "), .string, on: true, limit: 3)
               == .init(text: "abc…", dimmedRanges: []),
           "on: a mark the ellipsis cuts off loses its range")

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

    // MARK: - The setting cannot turn tier A off (Settings ▸ Results ▸ Cells)

    expect(cell(AnyCodable("safe\u{202E}gpj.exe"), .string, on: false).text == "safe<U+202E>gpj.exe",
           "off still discloses the override — the setting governs tier B only")
    // Flattening is NOT escaping: a label that silently becomes two lines is a
    // layout fault, so `↵` stays whatever the setting says.
    expect(cell(AnyCodable("a\nb"), .string, on: false).text == "a↵b", "off still flattens newlines")
    expect(cell(AnyCodable("a\nb"), .string, on: true).text == "a↵b", "on: the newline stays ↵, not <U+000A>")

    // MARK: - VoiceOver names the marks, not the glyphs

    expect(ResultCellText.accessibilityText(cell(AnyCodable("abc"), .string, on: true)) == nil,
           "no marks: no override, the label's own text is read")
    expect(ResultCellText.accessibilityText(cell(AnyCodable(" abc   "), .string, on: true))
               == "space abc 3 spaces", "edge spaces are counted in words")
    expect(ResultCellText.accessibilityText(cell(AnyCodable("a\tb"), .string, on: true)) == "a tab b",
           "a tab is named")
    expect(ResultCellText.accessibilityText(cell(AnyCodable("a\t "), .string, on: true)) == "a tab, space",
           "one range of mixed marks names each run")
    expect(ResultCellText.accessibilityText(cell(AnyCodable("a\u{A0}b"), .string, on: true)) == "a <U+00A0> b",
           "a token already names its character")

    // MARK: - Settings ▸ Results ▸ Formatting reaches the render boundary

    // The parser itself is tested in ResultValueFormatterTests. What is pinned
    // here is the wiring: that the boundary passes the kind and the styles
    // through, that the DEFAULT changes nothing, and the one rule that is this
    // file's own — formatted text is the app's output, so it is truncated but
    // never escaped.
    func rFmt(_ v: AnyCodable, _ c: PGTypeCategory, kind: ResultValueKind,
              date: ResultDateStyle = .asReturned, number: ResultNumberStyle = .asReturned,
              max: UInt32 = 0) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗",
                                nullString: "NULL", maximumCharacters: max,
                                kind: kind, dateStyle: date, numberStyle: number)
    }
    expect(rFmt(AnyCodable("2026-01-31 14:05:09"), .temporal, kind: .timestamp)
           == "2026-01-31 14:05:09",
           "formatting: the default leaves a timestamp exactly as it arrived")
    expect(rFmt(AnyCodable("1234567"), .numeric, kind: .integer) == "1234567",
           "formatting: the default leaves a number exactly as it arrived")
    expect(rFmt(AnyCodable("2026-01-31 14:05:09"), .temporal, kind: .timestamp, date: .iso8601T)
           == "2026-01-31T14:05:09",
           "formatting: the date style reaches the renderer")
    expect(rFmt(AnyCodable("2026-01-31 14:05:09"), .string, kind: .other, date: .iso8601T)
           == "2026-01-31 14:05:09",
           "formatting: a text column holding date-shaped text is never restyled")
    expect(rFmt(AnyCodable("not a timestamp"), .temporal, kind: .timestamp, date: .medium)
           == "not a timestamp",
           "formatting: a value the parser refuses is still drawn, unchanged")
    // A locale's own grouping separator is U+202F in fr and U+00A0 in ru, and
    // both are in `DisplayEscape.mustEscape`. Escaping the formatter's output
    // would draw every grouped number as `1<U+202F>234`, so it must not be
    // escaped — the same rule the NULL string and the boolean words follow.
    let localeGroup = { () -> String in
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.groupingSeparator ?? ","
    }()
    let groupedCell = rFmt(AnyCodable("1234567"), .numeric, kind: .integer, number: .grouped)
    expect(groupedCell.contains(localeGroup), "formatting: the number style reaches the renderer")
    expect(!groupedCell.contains("<U+"),
           "formatting: the formatter's own separator is never escaped as <U+XXXX>")
    // Truncation still applies: the limit is a limit on what is DRAWN.
    expect(rFmt(AnyCodable("1234567"), .numeric, kind: .integer, number: .grouped, max: 4).count == 5,
           "formatting: a formatted value is still cut at the limit, plus the ellipsis")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
