import Foundation

struct SavedQuery: Codable, Identifiable {
    let id: String
    var name: String
    var folder: String?
    var sql: String
    var connectionId: String?
    /// LEGACY. Saved queries once carried their own `[QueryVariable]` JSON here;
    /// variables are app-wide now (`QueryVariableStore`) and this column is
    /// neither written (every writer passes `nil`, which the Rust update treats
    /// as "leave unchanged") nor read. It stays on the wire because the Rust
    /// struct still has the field.
    var variables: String?
    let createdAt: String
    let updatedAt: String
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

struct CreateSavedQuery: Codable {
    let name: String
    let folder: String?
    let sql: String
    let connectionId: String?
    /// Legacy; always `nil`. See `SavedQuery.variables`.
    let variables: String?
}

struct UpdateSavedQuery: Codable {
    let id: String
    let name: String?
    let folder: String?
    let sql: String?
    /// Legacy; always `nil`. See `SavedQuery.variables`.
    let variables: String?
}
