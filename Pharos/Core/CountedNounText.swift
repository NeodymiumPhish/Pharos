import Foundation

/// "<count> <noun>", pluralised in English through automatic grammatical
/// agreement — the same `^[...](inflect: true)` markup a String Catalog
/// resolves — so a call site names only the singular noun and the runtime
/// works out "row" vs "rows" (and "0 rows", "1 row", "2 rows", …).
///
/// `AttributedString(localized:)` resolves the agreement even with no app
/// bundle or String Catalog behind it; plain `String(localized:)` does not —
/// it echoes the `^[...]` markup back unresolved. That is why this goes
/// through `AttributedString` and takes only the plain characters back out.
/// Verified, for every noun this type is actually asked to pluralise, in
/// `scripts/test-localized-plurals.sh`.
///
/// The inflector recognises ordinary English nouns from a built-in
/// dictionary, not arbitrary domain words — "tuple" is not in it and comes
/// back unpluralised ("2 tuple"), which that harness caught. Nouns the
/// inflector gets wrong are special-cased below instead of silently
/// shipping the wrong word.
enum CountedNounText {
    /// Nouns the automatic inflector cannot pluralise on its own, mapped to
    /// their plural form. Add to this only after the harness shows a miss —
    /// most English nouns do not need it.
    private static let irregularPlurals: [String: String] = [
        "tuple": "tuples"
    ]

    static func phrase(_ count: Int, _ singular: String) -> String {
        if count != 1, let plural = irregularPlurals[singular] {
            return "\(count.formatted()) \(plural)"
        }
        let attributed = AttributedString(localized: "^[\(count) \(singular)](inflect: true)")
        return String(attributed.characters)
    }
}
