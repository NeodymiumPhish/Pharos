import Foundation

/// Which query variables an AI app may use, and which `{{name}}` tokens of a
/// card or a past run it may not have filled in.
///
/// A variable is the app's to use when both hold (`MCPAccessPolicy.allowsVariable`):
/// its own "AI apps" choice (`QueryVariable.mcpAccess`, off until the user
/// chooses in the Variable Manager) includes the app's tier, and it is global
/// or linked to a connection shared with the app. One the app may not use
/// reads as one that does not exist: `list_variables` leaves it out, a run
/// that needs it is refused, and what a past run made with it is withheld.
///
/// Shared by `MCPToolHandlers` (the tier is the call's) and the run queue
/// (`ContentViewController.startJob`, the tier the run was asked with).
enum MCPVariableAccess {

    /// The connections shared with an app of this tier.
    static func sharedConnectionIds(isLocal: Bool, connections: [ConnectionConfig]) -> Set<String> {
        Set(connections.filter { $0.mcpAccess.allows(isLocal: isLocal) }.map(\.id))
    }

    /// Whether an app of this tier may use `variable`.
    static func allows(_ variable: QueryVariable, isLocal: Bool, allowed: Set<String>) -> Bool {
        MCPAccessPolicy.allowsVariable(connectionIds: variable.connectionIds,
                                       sharedWithApp: variable.mcpAccess.allows(isLocal: isLocal),
                                       allowed: allowed)
    }

    /// Those of `variables` an app of this tier may use. Unnamed rows (a new
    /// one the user has not named yet) are left out.
    static func usable(_ variables: [QueryVariable], isLocal: Bool, allowed: Set<String>) -> [QueryVariable] {
        variables.filter { !$0.name.isEmpty && allows($0, isLocal: isLocal, allowed: allowed) }
    }

    /// The `{{name}}` tokens in `texts` that are not among `usable`, sorted:
    /// a variable not shared with the app, one linked elsewhere, or one that
    /// no longer exists. The last two are withheld too, because nothing says
    /// what value the text was filled in with.
    static func withheldNames(in texts: [String?], usable: [QueryVariable]) -> [String] {
        var referenced: Set<String> = []
        for text in texts {
            if let text { referenced.formUnion(VariableSubstitutor.referencedNames(in: text)) }
        }
        return MCPAccessPolicy.withheldNames(referenced: referenced, usable: Set(usable.map(\.name)))
    }

    /// `{{a}}` or `{{a}} and {{b}}`, for a message to the app.
    static func tokenList(_ names: [String]) -> String {
        names.map { "{{\($0)}}" }.joined(separator: ", ")
    }
}
