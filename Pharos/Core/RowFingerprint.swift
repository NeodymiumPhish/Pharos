import Foundation

// MARK: - RowFingerprint

/// The canonical compare string for the fingerprint tier.
///
/// A fingerprint tag stores every column of a row, and matching it means
/// comparing strings exactly — Pharos does not hash. A plain join on a separator
/// would let a value forge a field boundary, because a result value can hold any
/// text. Every field is therefore length-prefixed, which makes the string
/// self-delimiting and needs no separator and no escape:
///
///     field(NULL)  = "N"
///     field(value) = "V" <byte count of the UTF-8 value> ":" <the value>
///     column(name) = "K" <byte count of the name> ":" <the name>
///     fingerprint  = column(n1) field(v1) column(n2) field(v2) …
///
/// Swift is the ONLY producer of a fingerprint. Rust produces the `pk` and
/// `unique` keys and Swift stores those verbatim, never rebuilding one. So the
/// two languages never have to agree on a byte here, and there is deliberately
/// no cross-language test vector — it would test a path that cannot exist.
enum RowFingerprint {

    /// One value, or a SQL NULL.
    ///
    /// The count is in UTF-8 BYTES. Counting characters would let "é" and a
    /// two-character value report the same length and collide.
    static func field(_ value: String?) -> String {
        guard let value else { return "N" }
        return "V\(value.utf8.count):\(value)"
    }

    /// One column name. A fingerprint pins its names into the string; a strong
    /// key does not, because its key columns come from the catalogue.
    static func column(_ name: String) -> String {
        "K\(name.utf8.count):\(name)"
    }

    /// The whole-row string, or nil when there is nothing to compare.
    ///
    /// Columns sort by their UTF-8 bytes, not by `String.<`. Byte order is the
    /// same everywhere; `String.<` is Unicode-aware and could in principle order
    /// two names differently under a different collation, which would make a
    /// stored fingerprint stop matching itself.
    static func encode(columns: [String], values: [String?]) -> String? {
        guard !columns.isEmpty, columns.count == values.count else { return nil }
        let pairs = zip(columns, values)
            .sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        return pairs.reduce(into: "") { out, pair in
            out += column(pair.0)
            out += field(pair.1)
        }
    }
}
