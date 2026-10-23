import Foundation

/// What the Database Navigator's pane shows in place of its tree while there
/// is no tree to show: no connection, the schema list or the shown schema's
/// tables still being read, or a read that failed. Pure (Foundation only), so
/// `scripts/test-navigator-pane-state.sh` pins it.
///
/// A large PostgreSQL database takes seconds to list its tables, and the pane
/// was blank for all of it. The HIG (Progress indicators) asks for a moving
/// indeterminate indicator for that wait, with a short description that says
/// what is happening rather than "Loading".
enum NavigatorPaneState: Equatable {
    /// The outline shows the tree (which may be empty).
    case tree
    case noConnection
    /// A spinning indicator and this line.
    case reading(String)
    /// A failed read: a title, the error, and Try Again.
    case failed(title: String, message: String)

    /// Where a read stands.
    enum Phase: Equatable {
        case pending
        case loaded
        case failed(String)
    }

    /// - Parameters:
    ///   - hasConnection: the navigator shows a connection.
    ///   - schemaList: the connection's schema list.
    ///   - pinned: the schema the tab pins, with its tables' phase; nil when
    ///     the navigator lists every schema (each one then shows its own
    ///     loading row) or the pinned schema is not in the list.
    static func resolve(hasConnection: Bool, schemaList: Phase, pinned: (schema: String, tables: Phase)?) -> Self {
        guard hasConnection else { return .noConnection }
        switch schemaList {
        case .pending:
            return .reading(String(localized: "Reading the schemas…"))
        case .failed(let message):
            return .failed(title: String(localized: "Couldn’t Read the Schemas"), message: message)
        case .loaded:
            break
        }
        guard let pinned else { return .tree }
        switch pinned.tables {
        case .pending:
            return .reading(String(localized: "Reading the tables in \(pinned.schema)…",
                                   comment: "The Database Navigator while a schema's table list loads; the schema's name."))
        case .failed(let message):
            return .failed(title: String(localized: "Couldn’t Read the Tables in \(pinned.schema)"), message: message)
        case .loaded:
            return .tree
        }
    }
}
