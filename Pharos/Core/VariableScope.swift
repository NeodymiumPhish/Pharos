import Foundation

/// Which query variables a tab can use.
///
/// A variable is global (every connection, the default) or linked to a set of
/// connection records. A tab on connection X sees the global ones and those
/// linked to X; a tab with no connection sees the global ones only. Names are
/// unique across the whole list (the Variable Manager refuses a duplicate), so
/// there is never a choice between two values for one name. Pure
/// (`scripts/test-variable-scope.sh`).
enum VariableScope {
    static func available(_ all: [QueryVariable], connectionId: String?) -> [QueryVariable] {
        all.filter { $0.isGlobal || (connectionId.map($0.connectionIds.contains) ?? false) }
    }

    /// The connections a variable named `name` is linked to, when it exists but
    /// the tab's connection is not one of them: the run error then says where
    /// it is defined instead of "undefined". Nil when it is available here, or
    /// does not exist at all.
    static func linkedElsewhere(name: String, in all: [QueryVariable], connectionId: String?) -> [String]? {
        guard let variable = all.first(where: { $0.name == name }), !variable.isGlobal,
              !(connectionId.map(variable.connectionIds.contains) ?? false) else { return nil }
        return variable.connectionIds
    }

    /// One connection the Variable Manager offers to link a variable to.
    struct LinkTarget: Equatable {
        let id: String
        /// The record no longer exists: shown as "Missing connection" so the
        /// link can be removed.
        let missing: Bool
    }

    /// What the Variable Manager lists for linking: every saved connection, the
    /// not-saved files and in-memory databases that are open now (a tab uses
    /// them, or they are connected), and whatever the variable is already
    /// linked to — a file that has closed since, or a record that is gone.
    /// Records keep the user's order; the gone ones come last.
    static func linkTargets(records: [ConnectionConfig], openIds: Set<String>, linked: [String]) -> [LinkTarget] {
        let linkedSet = Set(linked)
        var targets = records
            .filter { $0.saved || openIds.contains($0.id) || linkedSet.contains($0.id) }
            .map { LinkTarget(id: $0.id, missing: false) }
        let known = Set(records.map(\.id))
        targets += linked.filter { !known.contains($0) }.map { LinkTarget(id: $0, missing: true) }
        return targets
    }

    /// "{{env}} is linked to Prod and Staging, not to this tab's connection."
    /// `names` are the linked records' display names (escaped by the caller).
    static func linkedElsewhereMessage(name: String, connectionNames: [String]) -> String {
        let list = connectionNames.isEmpty
            ? String(localized: "connections that no longer exist")
            : ListFormatter.localizedString(byJoining: connectionNames)
        return String(localized: "{{\(name)}} is linked to \(list), not to this tab's connection.",
                      comment: "Run error: the variable exists but is linked to other connections.")
    }
}
