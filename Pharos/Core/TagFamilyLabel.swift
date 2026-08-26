import Foundation

// MARK: - TagFamilyLabel

/// One family string, one human label.
///
/// A condition is described by its FAMILY, not by a column. A column name
/// never takes part in matching — it is provenance — and a hand-authored
/// condition has no column at all, so the family is the one description
/// every condition can share. One producer, so the Inspector, the removal
/// sheet and the type picker cannot describe the same family with three
/// different words.
///
/// `DisplayEscape` on the way out, like every other stored text this app draws:
/// an exotic family carries a PostgreSQL type name, which is somebody else's
/// data.
enum TagFamilyLabel {

    /// Every family with a human name, in the order a picker should show them.
    static let known: [(family: String, label: String)] = [
        (TagValueNormalizer.textFamily, "Text"),
        (TagValueNormalizer.addressFamily, "Address"),
        (TagValueNormalizer.numericFamily, "Number"),
        (TagValueNormalizer.temporalFamily, "Date & time"),
        (TagValueNormalizer.uuidFamily, "UUID"),
    ]

    /// The label for one family, ready to draw.
    ///
    /// An unlisted family keeps its own text rather than becoming a stand-in
    /// word: `type:bool` is more use to an analyst than "Other", and a family
    /// this build has never seen must still say what it is.
    static func text(for family: String) -> String {
        if let known = known.first(where: { $0.family == family }) {
            return known.label
        }
        let prefix = TagValueNormalizer.typePrefix
        let bare = family.hasPrefix(prefix) ? String(family.dropFirst(prefix.count)) : family
        return DisplayEscape.escaped(bare)
    }
}
