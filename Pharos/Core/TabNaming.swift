import Foundation

/// The automatic name of a query tab.
///
/// A tab the user has not named is called "New Tab N" until it has a
/// connection, then "{connection} - {schema}" (with " (2)" when another tab
/// has that name), and it follows the connection and schema from then on. A
/// name the user gives it (`QueryTab.nameIsCustom`) stops all of that. Pure:
/// no AppKit and no connection records, so a harness compiles it alone
/// (`scripts/test-tab-naming.sh`).
enum TabNaming {
    /// "New Tab N" for the lowest N no open tab uses. The lowest free number,
    /// not one past the highest: a blank tab gives its number back when it
    /// connects and takes its connection's name, the way Safari numbers windows.
    /// Compared as whole names, so it holds in every language.
    static func nextNewTabName(used: [String]) -> String {
        let taken = Set(used)
        var n = 1
        while taken.contains(newTabName(n)) { n += 1 }
        return newTabName(n)
    }

    static func newTabName(_ n: Int) -> String {
        String(localized: "New Tab \(n)", comment: "The name of a new query tab that has no connection yet.")
    }

    /// "{connection} - {schema}", or the connection alone when there is no
    /// schema. `connection` is the name the user gave the connection record;
    /// `database` (the record's database field or file) stands in only when
    /// that name is empty.
    static func automaticName(connection: String, database: String = "", schema: String?) -> String {
        var label = connection.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = database.trimmingCharacters(in: .whitespacesAndNewlines) }
        let schema = schema?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !schema.isEmpty else { return label }
        guard !label.isEmpty else { return schema }
        return String(localized: "\(label) - \(schema)",
                      comment: "A query tab's automatic name: the connection, then the schema.")
    }

    /// `base` when no other tab is called that, else "base (2)", "base (3)",
    /// the lowest number free. Two tabs on one connection and schema are then
    /// told apart; the number is the tab's until its base changes.
    static func numbered(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains(numberedName(base, n)) { n += 1 }
        return numberedName(base, n)
    }

    static func numberedName(_ base: String, _ n: Int) -> String {
        String(localized: "\(base) (\(n))", comment: "A query tab's automatic name with a number, when another tab has the same name.")
    }
}
