import Foundation

// MARK: - RuleConditionKey

/// A condition as ENCODING compares it.
///
/// Deliberately not `TagValueKey`, which is `(family, value)` and is what the
/// MATCHER probes with. The two answer different questions: the matcher asks
/// "is this value present", and encoding asks "is this the same condition".
/// Sharing one type would collapse an `exact` and a `glob` on the same text
/// into one condition, because `encode` dedupes through `Set` — silently
/// narrowing the rule the analyst wrote.
struct RuleConditionKey: Hashable {
    let kind: TagConditionKind
    let family: String
    let value: String
    let operand2: String?
}

// MARK: - RuleKey

/// The canonical string for one rule — the duplicate key behind
/// `tag_tuples_identity`, which is what makes re-tagging a row into the same
/// tag a no-op.
///
/// It reuses `RowFingerprint`'s length-prefixed grammar rather than inventing a
/// second one:
///
///     kind(k)       = "P" <byte count> ":" <the kind>      (omitted when exact)
///     family(name)  = "K" <byte count> ":" <the family>
///     value(text)   = "V" <byte count> ":" <the text>
///     operand2(t)   = "W" <byte count> ":" <the text>      (omitted when nil)
///     rule          = condition(c1) condition(c2) …
///
/// The length prefix makes the string self-delimiting: a value can hold any
/// text, including text that looks exactly like this grammar, and a plain
/// separator would let it forge a field boundary and collide with another rule.
///
/// **The kind is omitted when it is `.exact`, and that is not tidiness — it is
/// the whole back-compatibility story.** Every key already in SQLite was built
/// when every condition was exact. Emitting `P5:exact` would change all of them
/// at once: every stored key would stop matching its own re-derived key, the
/// unique index would stop absorbing repeats, and re-tagging a row would
/// silently insert a duplicate rule instead of doing nothing. A `P`-prefixed
/// key cannot collide with an old one either, because every old key begins
/// with `K`.
///
/// Swift is the ONLY producer. Rust stores the string and compares it; it never
/// builds one, so the two languages never have to agree on a byte here.
enum RuleKey {

    /// One self-delimiting field.
    private static func field(_ tag: Character, _ text: String) -> String {
        "\(tag)\(text.utf8.count):\(text)"
    }

    /// Sorted by kind bytes, then family, then value, then operand2, so the
    /// order the analyst added the conditions in — or the order the columns
    /// happen to sit in a later result — cannot produce a second key for one
    /// rule.
    ///
    /// Bytes, not `String.<`: byte order is the same everywhere, while `<` is
    /// Unicode-aware and could order two strings differently under a different
    /// collation. A key is STORED and re-derived on a later query, so an
    /// unstable order would make a rule stop matching itself one day.
    ///
    /// Every existing condition is `.exact`, so the kind compares equal across
    /// all of them and the order falls through to family then value — today's
    /// order exactly.
    ///
    /// Duplicate conditions collapse. One present value satisfies every slot
    /// holding it, so a rule carrying the same condition twice states one fact,
    /// and its key must say so — otherwise the same finding captured from two
    /// identical columns would produce two rows.
    ///
    /// Returns nil for an empty input: an empty key would be shared by every
    /// conditionless rule and the unique index would fuse them into one.
    static func encode(_ conditions: [RuleConditionKey]) -> String? {
        guard !conditions.isEmpty else { return nil }
        let distinct = Array(Set(conditions)).sorted { a, b in
            // Bytes on BOTH sides of every decision, never String inequality:
            // choosing the branch by one rule and comparing inside it by
            // another would only be a total order by accident.
            if a.kind.rawValue.utf8.lexicographicallyPrecedes(b.kind.rawValue.utf8) { return true }
            if b.kind.rawValue.utf8.lexicographicallyPrecedes(a.kind.rawValue.utf8) { return false }
            if a.family.utf8.lexicographicallyPrecedes(b.family.utf8) { return true }
            if b.family.utf8.lexicographicallyPrecedes(a.family.utf8) { return false }
            if a.value.utf8.lexicographicallyPrecedes(b.value.utf8) { return true }
            if b.value.utf8.lexicographicallyPrecedes(a.value.utf8) { return false }
            return (a.operand2 ?? "").utf8.lexicographicallyPrecedes((b.operand2 ?? "").utf8)
        }
        return distinct.reduce(into: "") { out, condition in
            if condition.kind != .exact {
                out += field("P", condition.kind.rawValue)
            }
            // The exact path uses RowFingerprint's own helpers, UNCHANGED, so
            // its bytes are provably the same ones today's code emits.
            out += RowFingerprint.column(condition.family)
            out += RowFingerprint.field(condition.value)
            if let operand2 = condition.operand2 {
                out += field("W", operand2)
            }
        }
    }
}
