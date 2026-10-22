import Foundation

/// What the Dock icon's menu lists after New Tab. DuckDB files are left out:
/// the Dock already lists them as recent documents (File ▸ Open Recent's
/// list), and a short custom menu is easier to use. Pure, so the choice is
/// tested without the Dock, which shows a re-identified test copy's menu
/// only as the generic one.
enum DockMenuRule {
    enum Content {
        /// One item per record, in the list's order.
        case connections([ConnectionConfig])
        /// Only DuckDB files exist: no items, and no separator after New Tab.
        case onlyFiles
        /// No records at all: a disabled "No Connections" item.
        case none
    }

    /// PostgreSQL connections and in-memory DuckDB databases.
    static func content(for all: [ConnectionConfig]) -> Content {
        let listed = all.filter { !$0.isDuckDB || $0.isInMemoryDuckDB }
        if !listed.isEmpty { return .connections(listed) }
        return all.isEmpty ? .none : .onlyFiles
    }
}
