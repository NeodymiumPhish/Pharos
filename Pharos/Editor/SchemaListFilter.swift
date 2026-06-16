import Foundation

/// Pure filtering for the schema selector list. No AppKit dependencies —
/// unit-tested standalone via scripts/test-schema-list-filter.sh.
enum SchemaListFilter {

    /// Case-insensitive substring filter over schema names, preserving the
    /// original order. An empty or whitespace-only query returns all schemas
    /// unchanged.
    static func filter(_ schemas: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return schemas }
        return schemas.filter { $0.lowercased().contains(q) }
    }
}
