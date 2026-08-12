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
/// no cross-language test vector for the fingerprint AS A WHOLE — it would test
/// a path that cannot exist. The field grammar itself is a different matter: it
/// has two independent implementations. `field(_:)` below reproduces
/// `encode_field` in `pharos-core/src/commands/row_identity.rs` byte for byte —
/// same `"N"`, same `"V<len>:<value>"`, and Rust's `len()` on a `&str` is also
/// the UTF-8 byte count. A change to one grammar without the other will not
/// show up as a compile error on either side, only as a fingerprint that stops
/// matching itself — keep them in lockstep on purpose.
enum RowFingerprint {

    /// One value, or a SQL NULL.
    ///
    /// The count is in UTF-8 BYTES, because the comparison happens on the bytes
    /// that get compared later, not on the string's user-visible characters. A
    /// character count would let "é" (one character, two UTF-8 bytes) and a
    /// two-character ASCII value both report a length of "2", so the marker
    /// would no longer say where the value ends — the string would stop being
    /// self-delimiting in the one unit that actually matters at compare time.
    static func field(_ value: String?) -> String {
        guard let value else { return "N" }
        return "V\(value.utf8.count):\(value)"
    }

    /// One column name. A fingerprint pins its names into the string; a strong
    /// key does not, because its key columns come from the catalogue.
    ///
    /// Same byte-count rule as `field(_:)`, for the same reason: a non-ASCII
    /// column name counted in characters would under-report its own length.
    static func column(_ name: String) -> String {
        "K\(name.utf8.count):\(name)"
    }

    /// The whole-row string, or nil when there is nothing to compare.
    ///
    /// Columns sort by their UTF-8 bytes, not by `String.<`. Byte order is the
    /// same everywhere; `String.<` is Unicode-aware and could in principle order
    /// two names differently under a different collation, which would make a
    /// stored fingerprint stop matching itself.
    ///
    /// PostgreSQL freely returns duplicate column names, and this can happen in
    /// a result that falls to this tier — a read through a view, or a join that
    /// does not select all of the primary table's key columns. For a pair
    /// of equal names, `lexicographicallyPrecedes` is false in both directions,
    /// so a comparator built only from it is PARTIAL, and `sorted(by:)` is not
    /// guaranteed stable — the order of those two columns would be an
    /// unspecified implementation detail that could change under a stdlib
    /// update. A fingerprint is stored and re-derived on a later query, so an
    /// unstable order would make it silently stop matching itself one day.
    /// Tie-breaking on ORIGINAL POSITION makes the ordering total and
    /// deterministic. Tie-breaking on the VALUE instead would be worse than the
    /// bug it fixes: columns `["id", "id"]` with values `["1", "2"]` and
    /// `["2", "1"]` would then encode identically, merging two different rows.
    static func encode(columns: [String], values: [String?]) -> String? {
        guard !columns.isEmpty, columns.count == values.count else { return nil }
        let order = columns.indices.sorted { a, b in
            if columns[a].utf8.lexicographicallyPrecedes(columns[b].utf8) { return true }
            if columns[b].utf8.lexicographicallyPrecedes(columns[a].utf8) { return false }
            return a < b // equal names keep result order; the comparator must be total
        }
        return order.reduce(into: "") { out, i in
            out += column(columns[i])
            out += field(values[i])
        }
    }
}
