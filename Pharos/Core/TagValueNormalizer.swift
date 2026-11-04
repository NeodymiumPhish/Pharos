import Foundation

// MARK: - TagValueKey

/// A value as the matcher compares it. Column names are NOT in here: the design
/// makes them provenance, shown in the Inspector, never match input — that is
/// what lets a hash tagged under `cert_md5` surface later under
/// `certificate_hash` in another schema.
struct TagValueKey: Hashable {
    let family: String
    let value: String
}

// MARK: - TagValueNormalizer

/// The contract of the model: two values are the same indicator when their
/// family and their normalized text agree.
///
/// Every rule here trades a representation difference for a match. Case-folded
/// text and canonical addresses are analyst-friendly by decision, not by
/// accident — a hash that differs only in case is the same hash. Where a rule
/// cannot be applied safely, the fallback is always the EXACT text: a value
/// that fails to parse must keep its own identity rather than collapse into a
/// neighbour.
///
/// Pure, Foundation-only, and called once per result cell — so nothing in here
/// may allocate a `DateFormatter`.
enum TagValueNormalizer {

    static let addressFamily = "address"
    static let textFamily = "text"
    static let numericFamily = "numeric"
    static let temporalFamily = "temporal"
    static let uuidFamily = "uuid"

    /// The prefix `family(forDataType:)` puts on a type it has no rule for.
    /// Shared so the code that STRIPS it cannot drift from the code that adds it.
    static let typePrefix = "type:"

    /// The family of a column, from `ColumnDef.dataType`.
    ///
    /// Both spellings are listed for every family. `pharos-core` reports
    /// sqlx's short upper-case name (`INT4`, `TIMESTAMPTZ`), while the schema
    /// browser's own paths carry `information_schema`'s spelled-out name
    /// (`integer`, `timestamp with time zone`). `PGTypeCategory`
    /// (`Pharos/Utilities/PGTypeCategory.swift:19-31`) takes the same
    /// belt-and-braces approach for the same reason.
    ///
    /// An unlisted type keeps its own name as its family, so two different
    /// exotic types never compare equal just because their text matches.
    ///
    /// A JSON column keeps its own family too, for a rule captured from a whole
    /// document. The values INSIDE a document are keyed apart, by
    /// `jsonLeafKeys`.
    ///
    /// Two known gaps, both deliberate. A boolean lands in `type:bool` from
    /// sqlx and `type:boolean` from `information_schema`, so the two spellings
    /// do not share a family — harmless today, because every value that reaches
    /// this code comes from a query result and sqlx is its only source of type
    /// names. Array types (`INT4[]`, `TEXT[]`) get no family-level rule either
    /// and compare as exact text under their own name.
    static func family(forDataType dataType: String) -> String {
        let t = SQLTypeName.postgresEquivalent(dataType)
        switch t {
        case "inet", "cidr":
            return addressFamily
        case "text", "varchar", "character varying", "bpchar", "character",
             "char", "\"char\"", "name", "citext":
            return textFamily
        case "int2", "smallint", "int4", "integer", "int", "int8", "bigint",
             "numeric", "decimal", "float4", "real", "float8", "double precision",
             "money", "oid", "serial", "smallserial", "bigserial":
            return numericFamily
        case "date", "timestamp", "timestamptz", "time", "timetz",
             "timestamp without time zone", "timestamp with time zone",
             "time without time zone", "time with time zone":
            return temporalFamily
        case "uuid":
            return uuidFamily
        default:
            return "\(typePrefix)\(t)"
        }
    }

    /// The probe key for one cell, or nil for a SQL NULL.
    ///
    /// A NULL is the absence of a value, not a value, so it never keys anything
    /// and never matches anything — the design drops NULLs from a tuple at
    /// capture time for the same reason.
    static func key(text: String?, family: String) -> TagValueKey? {
        guard let text else { return nil }
        return TagValueKey(family: family, value: normalize(text, family: family))
    }

    static func normalize(_ text: String, family: String) -> String {
        switch family {
        case addressFamily:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return CIDRRange.canonical(trimmed) ?? trimmed
        case textFamily:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case numericFamily:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Two gates, and they catch different things. `isNumericText` is
            // grammar: `Decimal(string:)` reads a PREFIX, so "5-" would become
            // 5 and "-Infinity" would become a finite 0.
            // `significantDigitCount` is magnitude: past 38 digits `Decimal`
            // rounds a plain digit string instead of refusing it, so two
            // different values would collapse into one. Both failures are the
            // same failure — a FALSE MATCH — and exact text is the safe answer
            // to each.
            guard isNumericText(trimmed), significantDigitCount(trimmed) <= 38,
                  let value = Decimal(string: trimmed), value.isFinite
            else { return trimmed }
            return "\(value)"
        case temporalFamily:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return canonicalTimestamp(trimmed) ?? trimmed
        case uuidFamily:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .filter { $0 != "-" && $0 != "{" && $0 != "}" }
        default:
            // An unknown type compares byte for byte. Trimming here would be a
            // guess about a type this code does not understand.
            return text
        }
    }

    /// Every family with a rule of its own. A `type:<name>` family is not in
    /// here — it has no rule, so no predicate can ever answer it.
    static let everyFamily: [String] = [
        addressFamily, textFamily, numericFamily, temporalFamily, uuidFamily,
    ]

    // MARK: JSON

    /// Does this family hold a JSON document, whose values `jsonLeafKeys` reads?
    static func isJSONFamily(_ family: String) -> Bool {
        family == "\(typePrefix)json" || family == "\(typePrefix)jsonb"
    }

    /// One probe key per value inside a JSON document: each leaf is treated as a
    /// cell of its own, so a rule reaches into `json` and `jsonb` columns.
    ///
    /// JSON has no column type to supply a family, so the leaf's own shape does:
    ///
    ///  - A string is `text`. It is also `address`, `uuid` or `temporal` when ALL
    ///    of it parses as one, because JSON has no other way to spell those. All
    ///    three are strong filters: prose fails to parse.
    ///  - A string is never `numeric`, for the reason `TagPredicate.tests` gives
    ///    for text columns: plenty of prose is digits.
    ///  - A number is `numeric`, and `text` as well, because `{"id": 42}` and
    ///    `{"id": "42"}` are one producer's choice and the digits are on screen.
    ///  - A boolean is `text`.
    ///  - A `null` is the absence of a value, like a SQL NULL: no key.
    ///  - An object key is a name, and names take no part in matching.
    ///
    /// A document this cannot read gives no keys rather than the part read so
    /// far. A partly read document would satisfy some conditions of a rule and
    /// hide others, and neither can be explained in the grid.
    ///
    /// - Parameter families: only these are keyed. The caller passes the families
    ///   its rules use, which is what keeps `DateFormatter` and `inet_pton` off
    ///   every string of every document when no rule could use the answer.
    static func jsonLeafKeys(text: String?, families: Set<String>) -> [TagValueKey] {
        guard var document = text else { return [] }
        var keys = Set<TagValueKey>()
        let readable = document.withUTF8 { bytes in
            scanJSONLeaves(bytes) { leaf in
                switch leaf {
                case .string(let value):
                    insertStringKeys(value, families: families, into: &keys)
                case .number(let token):
                    if families.contains(numericFamily) {
                        keys.insert(TagValueKey(family: numericFamily,
                                                value: normalize(token, family: numericFamily)))
                    }
                    if families.contains(textFamily) {
                        keys.insert(TagValueKey(family: textFamily,
                                                value: normalize(token, family: textFamily)))
                    }
                case .boolean(let word):
                    if families.contains(textFamily) {
                        keys.insert(TagValueKey(family: textFamily, value: word))
                    }
                }
            }
        }
        return readable ? Array(keys) : []
    }

    private static func insertStringKeys(_ value: String, families: Set<String>,
                                         into keys: inout Set<TagValueKey>) {
        if families.contains(textFamily) {
            keys.insert(TagValueKey(family: textFamily, value: normalize(value, family: textFamily)))
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if families.contains(addressFamily), let canonical = CIDRRange.canonical(trimmed) {
            keys.insert(TagValueKey(family: addressFamily, value: canonical))
        }
        if families.contains(uuidFamily) {
            let hex = normalize(trimmed, family: uuidFamily)
            if hex.utf8.count == 32, hex.utf8.allSatisfy({ hexDigit($0) != nil }) {
                keys.insert(TagValueKey(family: uuidFamily, value: hex))
            }
        }
        if families.contains(temporalFamily), startsWithDate(trimmed),
           let canonical = canonicalTimestamp(trimmed) {
            keys.insert(TagValueKey(family: temporalFamily, value: canonical))
        }
    }

    /// Does this text begin `dddd-dd-dd`? Every form `canonicalTimestamp` parses
    /// does, and this answers for most strings without five `DateFormatter`
    /// attempts.
    private static func startsWithDate(_ text: String) -> Bool {
        var count = 0
        for byte in text.utf8.prefix(10) {
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            guard count == 4 || count == 7 ? byte == UInt8(ascii: "-") : isDigit else { return false }
            count += 1
        }
        return count == 10
    }

    private enum JSONLeaf {
        case string(String)
        /// The number's text as written. `Double` would round a wide integer, and
        /// two different identifiers would then match each other.
        case number(String)
        case boolean(String)
    }

    /// Walk a document's leaves, or return false when it cannot be read.
    ///
    /// A byte walk rather than `JSONSerialization`, for three reasons. The parser
    /// turns numbers into `NSNumber`, and the exact text is lost. It fails a whole
    /// document on a lone surrogate, which PostgreSQL's `json` type stores. It
    /// also keeps only the last of two equal keys, which `json` also stores, so a
    /// value shown in the grid would not match.
    ///
    /// The walk checks tokens, not grammar: the server has already validated the
    /// document. It is iterative, so nesting depth cannot overflow the stack.
    private static func scanJSONLeaves(_ bytes: UnsafeBufferPointer<UInt8>,
                                       visit: (JSONLeaf) -> Void) -> Bool {
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"),
                 UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: ","), UInt8(ascii: ":"):
                i += 1

            case UInt8(ascii: "\""):
                guard let (end, hasEscape) = jsonStringEnd(bytes, from: i + 1) else { return false }
                var next = end + 1
                while next < bytes.count, isJSONWhitespace(bytes[next]) { next += 1 }
                // A string followed by a colon is always an object key.
                if next < bytes.count, bytes[next] == UInt8(ascii: ":") {
                    i = next + 1
                    continue
                }
                let body = UnsafeBufferPointer(rebasing: bytes[(i + 1)..<end])
                if hasEscape {
                    guard let value = decodeJSONEscapes(body) else { return false }
                    visit(.string(value))
                } else {
                    visit(.string(String(decoding: body, as: UTF8.self)))
                }
                i = end + 1

            case UInt8(ascii: "t"):
                guard jsonLiteral("true", in: bytes, at: i) else { return false }
                visit(.boolean("true"))
                i += 4

            case UInt8(ascii: "f"):
                guard jsonLiteral("false", in: bytes, at: i) else { return false }
                visit(.boolean("false"))
                i += 5

            case UInt8(ascii: "n"):
                guard jsonLiteral("null", in: bytes, at: i) else { return false }
                i += 4

            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                var end = i + 1
                while end < bytes.count, isJSONNumberByte(bytes[end]) { end += 1 }
                let token = String(decoding: UnsafeBufferPointer(rebasing: bytes[i..<end]), as: UTF8.self)
                guard isNumericText(token) else { return false }
                visit(.number(token))
                i = end

            default:
                return false
            }
        }
        return true
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }

    private static func isJSONNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"),
             UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return false
        }
    }

    private static func jsonLiteral(_ word: StaticString, in bytes: UnsafeBufferPointer<UInt8>,
                                    at start: Int) -> Bool {
        let count = word.utf8CodeUnitCount
        guard start + count <= bytes.count else { return false }
        return word.withUTF8Buffer { literal in
            (0..<count).allSatisfy { bytes[start + $0] == literal[$0] }
        }
    }

    /// The index of a string's closing quote, or nil when it has none.
    private static func jsonStringEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int)
        -> (end: Int, hasEscape: Bool)? {
        var i = start
        var hasEscape = false
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\""):
                return (i, hasEscape)
            case UInt8(ascii: "\\"):
                hasEscape = true
                i += 2
            default:
                i += 1
            }
        }
        return nil
    }

    /// A string's text with its escapes decoded, or nil for an invalid escape. A
    /// lone surrogate becomes U+FFFD: it has no text of its own to compare, and
    /// the rest of the document is still readable.
    private static func decodeJSONEscapes(_ body: UnsafeBufferPointer<UInt8>) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var i = 0
        while i < body.count {
            let byte = body[i]
            i += 1
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                continue
            }
            guard i < body.count else { return nil }
            let escape = body[i]
            i += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard var unit = hexUnit(body, at: i) else { return nil }
                i += 4
                if (0xD800...0xDBFF).contains(unit), i + 6 <= body.count,
                   body[i] == UInt8(ascii: "\\"), body[i + 1] == UInt8(ascii: "u"),
                   let low = hexUnit(body, at: i + 2), (0xDC00...0xDFFF).contains(low) {
                    unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                let scalar = Unicode.Scalar(unit) ?? "\u{FFFD}"
                out.append(contentsOf: String(scalar).utf8)
            default:
                return nil
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexUnit(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> UInt32? {
        guard start + 4 <= bytes.count else { return nil }
        var unit: UInt32 = 0
        for i in start..<(start + 4) {
            guard let digit = hexDigit(bytes[i]) else { return nil }
            unit = unit << 4 | digit
        }
        return unit
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }

    // MARK: Comparable forms

    /// The `Decimal` a NORMALIZED numeric value holds, or nil when that value
    /// fell back to raw text.
    ///
    /// Comparators must never compare numeric text by bytes. The normalized
    /// form is `"\(Decimal)"`, which is neither fixed width nor sign-ordered:
    /// byte order puts `"9"` above `"10"` and puts every negative number in the
    /// wrong place.
    ///
    /// nil is the answer for a value that FELL BACK. `normalize` keeps
    /// unparseable text as-is, so `-Infinity`, `5-`, `1,000` and a 39-digit
    /// number all arrive here as themselves. A comparator against one must fail
    /// to match, not compare bytes — a byte compare there is exactly the false
    /// match `isNumericText` and `significantDigitCount` exist to prevent. It is
    /// the SAME pair of gates here, in the same file, rather than a second copy
    /// that could drift from the one matching actually used.
    static func decimal(from normalized: String) -> Decimal? {
        guard isNumericText(normalized), significantDigitCount(normalized) <= 38,
              let value = Decimal(string: normalized), value.isFinite
        else { return nil }
        return value
    }

    /// A NORMALIZED temporal value as a byte-comparable string, or nil when
    /// that value fell back to raw text.
    ///
    /// The whole job is to DROP THE TRAILING `Z`, and that is not a tidy-up —
    /// it is the comparison. The canonical form keeps every fractional digit,
    /// so `…56.9Z` and `…56.91Z` differ in LENGTH; with the `Z` still attached,
    /// byte order compares `Z` against `1` and ranks `.9` ABOVE `.91`, which is
    /// backwards.
    ///
    /// With the `Z` gone, byte order IS time order, and no padding is needed.
    /// `canonicalTimestamp` strips trailing zeros, so a canonical fraction never
    /// ends in `0`. Two consequences follow, and together they cover every case:
    /// if one fraction is a prefix of another, the longer one carries an extra
    /// non-zero digit and really is larger, which is the order a prefix already
    /// sorts in; and if two fractions diverge, the first differing digit decides
    /// the byte order and the numeric order alike. Everything left of the
    /// fraction is fixed width and already ordered.
    ///
    /// An earlier draft padded the fraction to nine digits. That was a second
    /// defence against a hazard dropping the `Z` had already removed, and it
    /// cost a real failure: a fraction longer than nine digits returned nil, so
    /// a valid timestamp silently stopped matching.
    ///
    /// The gate is `canonicalTimestamp`'s own IDEMPOTENCE: a value that is its
    /// own canonical form parsed, and a value that fell back did not. That is
    /// one source of truth rather than a second parser here — and it is why raw
    /// text that happens to end in `Z` is refused instead of being turned into a
    /// comparable-looking string.
    static func comparableTimestamp(_ normalized: String) -> String? {
        guard canonicalTimestamp(normalized) == normalized else { return nil }
        return String(normalized.dropLast())
    }

    // MARK: Numeric

    /// Is this the text of a number, all of it?
    ///
    /// `Decimal(string:)` cannot answer this. It scans a PREFIX and gives back
    /// what it managed to read, so "5-" becomes 5, "1,000" becomes 1, and
    /// "-Infinity" becomes 0 — finite, so an `isFinite` check waves it through.
    /// The cost of that is a FALSE MATCH: tag a `-infinity` float8 and every
    /// literal zero in that column matches it. So the grammar is checked here
    /// first, and anything that fails it keeps its exact text and matches only
    /// itself. `Decimal(string:)` DOES refuse an out-of-range exponent
    /// (`"1e400"` is nil), but grammar alone cannot catch a plain digit string
    /// that is too wide — that is `significantDigitCount`'s job, not this one's.
    ///
    /// The grammar is PostgreSQL's own numeric output: an optional sign, digits
    /// with an optional single point, and an optional exponent. Written as a
    /// character walk rather than a regex because this runs per cell.
    static func isNumericText(_ text: String) -> Bool {
        var chars = Substring(text)
        if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }

        var mantissaDigits = 0
        var seenPoint = false
        while let c = chars.first, c.isASCII, c == "." || c.isNumber {
            if c == "." {
                if seenPoint { return false }   // a second point is not a number
                seenPoint = true
            } else {
                mantissaDigits += 1
            }
            chars = chars.dropFirst()
        }
        guard mantissaDigits > 0 else { return false }   // "." and "-" are not numbers
        guard !chars.isEmpty else { return true }

        guard chars.first == "e" || chars.first == "E" else { return false }
        chars = chars.dropFirst()
        if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
        guard !chars.isEmpty, chars.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return true
    }

    /// How many digits of precision this text actually asks for.
    ///
    /// `Decimal` holds 38 significant digits. Past that it does NOT refuse a
    /// plain digit string — it rounds the low-order digits away and stays
    /// finite, so two `numeric` values differing only past the 38th digit
    /// collapse into one string and match each other. Grammar cannot catch
    /// that; only magnitude can.
    ///
    /// Leading AND trailing zeros are free: `1` followed by forty zeros is one
    /// significant digit and `Decimal` holds it exactly as a mantissa and an
    /// exponent, so rejecting it would lose a match for nothing. Digits after
    /// an `e` are an exponent, not precision, so counting stops there.
    private static func significantDigitCount(_ text: String) -> Int {
        var digits: [Character] = []
        for c in text {
            if c == "e" || c == "E" { break }
            if c.isASCII, c.isNumber { digits.append(c) }
        }
        var start = 0
        while start < digits.count, digits[start] == "0" { start += 1 }
        var end = digits.count
        while end > start, digits[end - 1] == "0" { end -= 1 }
        return end - start
    }

    // MARK: Timestamps

    /// Built ONCE, not per call. `normalize` runs over every cell of every
    /// result, and a `DateFormatter` is expensive to construct — making these
    /// computed would rebuild one per cell and is the obvious "tidy-up" that
    /// must not happen. Sharing them across threads is safe: they are immutable
    /// after construction, and `DateFormatter` is `Sendable` on this toolchain.
    private static let inputFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
    ].map(makeFormatter)

    private static let outputFormatter =
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // POSIX locale and a fixed UTC zone: a formatter that follows the
        // user's locale would normalize the same value differently on two
        // machines, and a stored tag would stop matching itself abroad.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// One ISO-8601 form in UTC, keeping every fractional digit.
    ///
    /// The fraction is cut out BEFORE parsing and put back after. A format
    /// string can only carry a fixed number of `S` places, so parsing through a
    /// formatter truncates: `12:34:56.789123` and `12:34:56.789456` would both
    /// normalize to `…789`, and two different observations a microsecond apart
    /// would match each other. A false match is the one failure direction this
    /// model cannot tolerate, so precision is preserved by hand.
    ///
    /// A date with no time normalizes to midnight UTC on purpose: a `date`
    /// column and a `timestamp` column holding the same instant then agree.
    ///
    /// Returns nil when nothing parses — a bare `time` value, an interval, an
    /// exotic format — and the caller keeps the exact text.
    static func canonicalTimestamp(_ text: String) -> String? {
        let (stripped, fraction) = splitFraction(text)
        for formatter in inputFormatters {
            guard let date = formatter.date(from: stripped) else { continue }
            let base = outputFormatter.string(from: date)
            return fraction.isEmpty ? "\(base)Z" : "\(base).\(fraction)Z"
        }
        return nil
    }

    /// Split `2026-08-13 12:34:56.789000+01` into
    /// (`2026-08-13 12:34:56+01`, `789`). Trailing zeros go, because `.789` and
    /// `.789000` are one instant.
    private static func splitFraction(_ text: String) -> (stripped: String, fraction: String) {
        guard let dot = text.firstIndex(of: ".") else { return (text, "") }
        var digits = ""
        var index = text.index(after: dot)
        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }
        // A dot with no digits after it is not a fraction (and cannot come from
        // PostgreSQL); leave the text alone rather than mangling it.
        guard !digits.isEmpty else { return (text, "") }
        var stripped = text
        stripped.removeSubrange(dot..<index)
        while digits.last == "0" { digits.removeLast() }
        return (stripped, digits)
    }
}
