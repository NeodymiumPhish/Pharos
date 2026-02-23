import Foundation

struct SavedQuery: Codable, Identifiable {
    let id: String
    var name: String
    var folder: String?
    var sql: String
    var connectionId: String?
    let createdAt: String
    let updatedAt: String
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

struct CreateSavedQuery: Codable {
    let name: String
    let folder: String?
    let sql: String
    let connectionId: String?
}

struct UpdateSavedQuery: Codable {
    let id: String
    let name: String?
    let folder: String?
    let sql: String?
}
