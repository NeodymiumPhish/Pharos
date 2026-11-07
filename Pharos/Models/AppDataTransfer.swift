import Foundation

// MARK: - App data export and import
//
// File ▸ Export App Data… and File ▸ Import App Data…. Mirrors the wire types
// in `pharos-core/src/commands/app_backup.rs`; both sides use camelCase and
// `JSONEncoder.pharos` applies no key strategy, so the property names here ARE
// the JSON keys.

/// The kinds of data an export writes, or an import reads.
struct AppDataCategories: Codable, Equatable {
    var sessions = false
    var history = false
    var connections = false
    var tags = false
    var variables = false

    var isEmpty: Bool { !(sessions || history || connections || tags || variables) }

    static let all = AppDataCategories(sessions: true, history: true, connections: true, tags: true, variables: true)

    /// The categories this summary says the file holds.
    static func present(in summary: AppDataSummary) -> AppDataCategories {
        AppDataCategories(sessions: summary.sessions != nil,
                          history: summary.history != nil,
                          connections: summary.connections != nil,
                          tags: summary.tags != nil,
                          variables: summary.variables != nil)
    }
}

struct ExportAppDataOptions: Encodable {
    let path: String
    let categories: AppDataCategories
    let includeSessionResults: Bool
    /// Required when `categories.connections`: a file with passwords in it is
    /// always encrypted.
    let passphrase: String?
}

/// What an import does with an item this Mac already has (the same id).
enum AppDataConflictPolicy: String, Codable, CaseIterable {
    /// The file's copy wins.
    case replace
    /// This Mac's copy stays.
    case keep
}

struct ImportAppDataOptions: Encodable {
    let path: String
    let passphrase: String?
    let categories: AppDataCategories
    let conflict: AppDataConflictPolicy
}

/// What a file holds. A count is nil when the file does not hold that
/// category at all. An encrypted file read without its password is `locked`
/// and has no counts.
struct AppDataSummary: Decodable, Equatable {
    let version: Int
    let encrypted: Bool
    let locked: Bool
    let exportedAt: String?
    let sessions: Int?
    let sessionResults: Int?
    let history: Int?
    let connections: Int?
    let connectionSecrets: Int?
    let tags: Int?
    let variables: Int?
}

struct ExportAppDataResult: Decodable {
    let summary: AppDataSummary
    let bytes: UInt64
}

struct AppDataCategoryOutcome: Decodable, Equatable {
    let added: Int
    let replaced: Int
    /// Already on this Mac and kept.
    let skipped: Int
}

struct ImportAppDataResult: Decodable {
    let sessions: AppDataCategoryOutcome?
    let history: AppDataCategoryOutcome?
    let connections: AppDataCategoryOutcome?
    let tags: AppDataCategoryOutcome?
    let variables: AppDataCategoryOutcome?
}

/// One of the five kinds of data, for the export and import forms.
enum AppDataCategory: CaseIterable {
    case sessions, history, connections, tags, variables

    var keyPath: WritableKeyPath<AppDataCategories, Bool> {
        switch self {
        case .sessions: return \.sessions
        case .history: return \.history
        case .connections: return \.connections
        case .tags: return \.tags
        case .variables: return \.variables
        }
    }

    var title: String {
        switch self {
        case .sessions: return String(localized: "Sessions")
        case .history: return String(localized: "Query History")
        case .connections: return String(localized: "Connections, with their passwords")
        case .tags: return String(localized: "Tags")
        case .variables: return String(localized: "Variables")
        }
    }

    /// How many of this category `summary` says the file holds; nil when it
    /// holds none of it at all.
    func count(in summary: AppDataSummary) -> Int? {
        switch self {
        case .sessions: return summary.sessions
        case .history: return summary.history
        case .connections: return summary.connections
        case .tags: return summary.tags
        case .variables: return summary.variables
        }
    }

    func outcome(in result: ImportAppDataResult) -> AppDataCategoryOutcome? {
        switch self {
        case .sessions: return result.sessions
        case .history: return result.history
        case .connections: return result.connections
        case .tags: return result.tags
        case .variables: return result.variables
        }
    }
}
