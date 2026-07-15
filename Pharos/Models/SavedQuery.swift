import Foundation

struct SavedQuery: Codable, Identifiable {
    let id: String
    var name: String
    var folder: String?
    var sql: String
    var connectionId: String?
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
    let variables: String?
}

struct UpdateSavedQuery: Codable {
    let id: String
    let name: String?
    let folder: String?
    let sql: String?
    let variables: String?
}

extension Array where Element == QueryVariable {
    /// Serialize to a JSON string for saved-query storage. Always returns a
    /// string (empty array -> "[]") so clearing all variables is persisted,
    /// rather than being skipped by the Rust update (which treats nil as
    /// "leave column unchanged").
    func toSavedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SavedQueryVariables {
    /// Decode a saved-query `variables` JSON string; [] if nil/invalid.
    static func decode(_ json: String?) -> [QueryVariable] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QueryVariable].self, from: data)) ?? []
    }
}
