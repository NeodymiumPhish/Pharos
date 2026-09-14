import Foundation

// The Rust mirrors (`pharos-core/src/models/session.rs`) use
// `#[serde(rename_all = "camelCase")]`, and `JSONDecoder.pharos` applies NO key
// strategy, so these property names ARE the JSON keys. Every field must exist on
// both sides: `load_session` re-serializes the Rust struct, so a Swift-only
// field would make the synthesized decode throw.

/// One editor tab as it was left at the end of the last run.
struct SessionTab: Codable, Equatable {
    /// Position in the tab bar, 0-based.
    var tabIndex: Int
    /// Set only for a tab that has run a query. The workspace row holds the
    /// authoritative editor text, variables and cursor for such a tab; the
    /// copies below are the fallback for a workspace that no longer exists.
    var workspaceId: String?
    var name: String
    /// False when `name` is the generated "Query <n>".
    var nameIsCustom: Bool
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int
    /// `[QueryVariable]` encoded as JSON, exactly as a workspace snapshot stores it.
    var variablesJson: String?
    var isActive: Bool
}

/// The whole set of open tabs, in tab-bar order.
struct Session: Codable, Equatable {
    var tabs: [SessionTab] = []
}
