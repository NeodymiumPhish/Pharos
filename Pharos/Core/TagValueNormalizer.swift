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
    /// Two known gaps, both deliberate. A boolean lands in `type:bool` from
    /// sqlx and `type:boolean` from `information_schema`, so the two spellings
    /// do not share a family — harmless today, because every value that reaches
    /// this code comes from a query result and sqlx is its only source of type
    /// names. Array types (`INT4[]`, `TEXT[]`) get no family-level rule either
    /// and compare as exact text under their own name.
    static func family(forDataType dataType: String) -> String {
        let t = dataType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    private static func isNumericText(_ text: String) -> Bool {
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
