import Foundation

// MARK: - RuleKey

/// The canonical string for one tuple — the duplicate key behind
/// `tag_tuples_identity`, which is what makes re-tagging a row into the same
/// tag a no-op.
///
/// It reuses `RowFingerprint`'s length-prefixed grammar rather than inventing a
/// second one:
///
///     family(name)  = "K" <byte count> ":" <the family>
///     value(text)   = "V" <byte count> ":" <the text>
///     tuple         = family(f1) value(v1) family(f2) value(v2) …
///
/// The prefix is what makes the string self-delimiting: a captured value can
/// hold any text, including text that looks exactly like this grammar, and a
/// plain separator would let it forge a field boundary and collide with a
/// different tuple.
///
/// Swift is the ONLY producer. Rust stores the string and compares it; it never
/// builds one, so the two languages never have to agree on a byte here.
enum RuleKey {

    /// Sorted by family bytes then value bytes, so the order the analyst ticked
    /// the columns in — or the order the columns happen to sit in a later
    /// result — cannot produce a second key for one finding.
    ///
    /// Bytes, not `String.<`: byte order is the same everywhere, while `<` is
    /// Unicode-aware and could in principle order two strings differently under
    /// a different collation. A key is STORED and re-derived later, so an
    /// unstable order would make a tuple stop matching itself one day.
    ///
    /// Duplicate pairs collapse. One present value satisfies every slot holding
    /// it, so a tuple carrying the same value twice states one fact, and its key
    /// must say so — otherwise the same finding captured from two identical
    /// columns would produce two rows.
    ///
    /// Returns nil for an empty input: an empty key would be shared by every
    /// valueless tuple and the unique index would fuse them into one.
    static func encode(_ values: [TagValueKey]) -> String? {
        guard !values.isEmpty else { return nil }
        let distinct = Array(Set(values)).sorted { a, b in
            // Bytes on BOTH sides of the decision, not just inside the
            // branches. `a.family != b.family` would be Swift string
            // inequality, which is canonical-equivalence-based, so the choice
            // of branch would follow one rule and the comparison inside it
            // another — and the comparator would only be a total order because
            // every family in use today happens to be ASCII. This shape is
            // total over the deduped input by construction: `Set` has already
            // removed anything canonically equal, and two strings with equal
            // bytes ARE equal, so any two survivors differ in the family bytes
            // or in the value bytes.
            if a.family.utf8.lexicographicallyPrecedes(b.family.utf8) { return true }
            if b.family.utf8.lexicographicallyPrecedes(a.family.utf8) { return false }
            return a.value.utf8.lexicographicallyPrecedes(b.value.utf8)
        }
        return distinct.reduce(into: "") { out, pair in
            out += RowFingerprint.column(pair.family)
            out += RowFingerprint.field(pair.value)
        }
    }
}
