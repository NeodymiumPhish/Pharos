import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Connection

/// A saved connection, as Shortcuts and Siri see it.
struct ConnectionEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Connection", numericFormat: "\(placeholder: .int) connections")
    }

    static var defaultQuery = ConnectionQuery()

    let id: String
    let name: String
    let host: String
    let database: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(database) — \(host)")
    }

    init(_ config: ConnectionConfig) {
        self.id = config.id
        self.name = config.name
        self.host = config.host
        self.database = config.database
    }

    /// Every saved connection. `AppStateManager` is the one list the rest of the
    /// app reads, so an intent shows exactly what the sidebar shows.
    @MainActor
    static func all() -> [ConnectionEntity] {
        AppStateManager.shared.connections.map(ConnectionEntity.init)
    }
}

/// `EntityStringQuery` rather than a plain `EntityQuery` because the App Shortcut
/// phrase names this parameter: Siri hands the spoken words over as a string and
/// needs somewhere to match them.
struct ConnectionQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [ConnectionEntity] {
        let wanted = Set(identifiers)
        return await MainActor.run { ConnectionEntity.all().filter { wanted.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [ConnectionEntity] {
        let needle = string.lowercased()
        return await MainActor.run {
            ConnectionEntity.all().filter {
                $0.name.lowercased().contains(needle)
                    || $0.database.lowercased().contains(needle)
                    || $0.host.lowercased().contains(needle)
            }
        }
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        await MainActor.run { ConnectionEntity.all() }
    }
}

// MARK: - Saved query

/// A saved query, as Shortcuts, Siri and Spotlight see it.
///
/// `IndexedEntity` is what puts it in Spotlight: `SavedQuerySpotlightIndexer`
/// hands these to `CSSearchableIndex.indexAppEntities`, and the system opens the
/// matching entity through `OpenSavedQueryIntent`.
struct SavedQueryEntity: AppEntity, IndexedEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Saved Query", numericFormat: "\(placeholder: .int) saved queries")
    }

    static var defaultQuery = SavedQueryQuery()

    let id: String
    let name: String
    let folder: String?
    let sql: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(folder ?? "")")
    }

    init(_ query: SavedQuery) {
        self.id = query.id
        self.name = query.name
        self.folder = query.folder
        self.sql = query.sql
    }

    /// What Spotlight stores. The first line of the SQL is the description: a
    /// whole statement in the result subtitle is unreadable, and the first line
    /// is what the saved-queries list already shows.
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = name
        set.contentDescription = Self.firstLine(of: sql)
        if let folder, !folder.isEmpty { set.keywords = [folder] }
        return set
    }

    static func firstLine(of sql: String) -> String {
        let line = sql
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(line ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Every saved query, read straight from the core. There is no in-memory
    /// list to read instead — `SavedQueriesVC` loads the same way.
    static func all() -> [SavedQueryEntity] {
        ((try? PharosCore.loadSavedQueries()) ?? []).map(SavedQueryEntity.init)
    }

    /// The stored record behind this entity, or nil when it has been deleted
    /// since the entity was made. Intents re-read it so they open the current
    /// SQL and variables, not a stale copy Shortcuts held on to.
    static func stored(id: String) -> SavedQuery? {
        ((try? PharosCore.loadSavedQueries()) ?? []).first { $0.id == id }
    }
}

struct SavedQueryQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [SavedQueryEntity] {
        let wanted = Set(identifiers)
        return SavedQueryEntity.all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SavedQueryEntity] {
        let needle = string.lowercased()
        return SavedQueryEntity.all().filter {
            $0.name.lowercased().contains(needle) || ($0.folder?.lowercased().contains(needle) ?? false)
        }
    }

    func suggestedEntities() async throws -> [SavedQueryEntity] {
        SavedQueryEntity.all()
    }
}

// MARK: - Workspace

/// One workspace-history record — an editor tab with the results it produced.
struct WorkspaceEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Workspace", numericFormat: "\(placeholder: .int) workspaces")
    }

    static var defaultQuery = WorkspaceQuery()

    let id: String
    let name: String
    let connectionName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(connectionName)")
    }

    init(_ summary: WorkspaceSummary) {
        self.id = summary.id
        self.name = summary.name
        self.connectionName = summary.connectionName
    }

    static func all() -> [WorkspaceEntity] {
        ((try? PharosCore.loadWorkspaces()) ?? []).map(WorkspaceEntity.init)
    }
}

struct WorkspaceQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        let wanted = Set(identifiers)
        return WorkspaceEntity.all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        let needle = string.lowercased()
        return WorkspaceEntity.all().filter {
            $0.name.lowercased().contains(needle) || $0.connectionName.lowercased().contains(needle)
        }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        WorkspaceEntity.all()
    }
}
