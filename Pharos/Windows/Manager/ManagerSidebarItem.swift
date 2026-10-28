import AppKit

/// One row of a manager window's sidebar (`ManagerSidebarVC`): what the row
/// says and what it carries, with no view in it. The Variable, Tag and
/// Connection Managers each map their own records onto this.
///
/// - Variables: `{{name}}` monospaced, "Number · 42", a warning when the
///   value would break a query.
/// - Tags: a colour swatch, the tag's name, "3 rules".
/// - Connections: the engine symbol, `host:port · db`, a status dot, and the
///   unsaved dot while the form has edits.
///
/// Colours are carried as `NSColor` and resolved only when the cell DRAWS,
/// so a dynamic system colour follows Light and Dark without a reload.
struct ManagerSidebarItem: Equatable {

    /// The square at the row's leading edge.
    enum Badge: Equatable {
        case none
        /// A white SF Symbol on a tinted rounded square (`SettingsSymbolBadge`).
        /// A nil tint is the badge's neutral grey.
        case symbol(name: String, tint: NSColor?)
        /// A filled colour dot, the shape `TagPalette.swatch` uses.
        case swatch(NSColor)
    }

    /// A mark at the row's trailing edge. A row shows every accessory in its
    /// list, leading to trailing; an empty list shows none.
    enum Accessory: Equatable {
        /// A red warning triangle. The text is its tooltip and what VoiceOver
        /// reads.
        case warning(tooltip: String)
        /// The orange dot of a record with unsaved edits.
        case unsavedDot
        /// A connection's state. A nil colour draws an empty ring, as
        /// `TabConnectionDot` does for "not connected". The label is what
        /// VoiceOver reads, because the colour alone says nothing to it.
        case statusDot(NSColor?, accessibilityLabel: String)
    }

    /// Stable across reloads; selection is kept by it.
    let id: String
    var title: String
    var titleIsMonospaced: Bool = false
    /// The second line, in the secondary colour. Nil gives a one-line row.
    var subtitle: String?
    /// Truncate a long subtitle in the middle (a file path) rather than at
    /// the end (a value).
    var subtitleTruncatesMiddle: Bool = false
    var badge: Badge = .none
    var trailing: [Accessory] = []

    /// True when `filter` occurs in the title or the subtitle, ignoring case
    /// and diacritics (`localizedStandardContains`, the comparison Apple
    /// recommends for a user's search). An empty or all-blank filter matches
    /// everything.
    func matches(_ filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if title.localizedStandardContains(needle) { return true }
        return subtitle?.localizedStandardContains(needle) ?? false
    }

    /// What type-select matches against: the title without its leading
    /// punctuation and symbols, so typing "n" finds `{{name}}`. An underscore
    /// is kept, since it can start a name. Falls back to the whole title when
    /// nothing would be left.
    var typeSelectText: String {
        let stripped = title.drop { character in
            character != "_" && character.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
        return stripped.isEmpty ? title : String(stripped)
    }
}
