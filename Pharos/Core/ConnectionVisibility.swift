import Foundation

/// Which connection records each list shows.
///
/// A record is either saved (every server, and a DuckDB file or in-memory
/// database the user chose Save as Connection for) or not saved (a file that
/// was only opened). Not-saved records stay in the store — tabs, Sessions,
/// history and workspaces refer to their id, and a lookup by id or by path
/// still finds them — but the lists of connections to choose from leave them
/// out, except where a tab is using one. Pure, so the rule is tested without
/// the app (`scripts/test-connection-visibility.sh`).
enum ConnectionVisibility {
    /// The tab pop-up's three groups, in the order they are shown.
    enum Section: Equatable {
        /// Not-saved files and in-memory databases a tab is using.
        case openFiles
        case postgres
        /// Saved DuckDB files and in-memory databases.
        case duckdb
    }

    /// The Connections Manager, Shortcuts' suggestions and name search, the
    /// Dock menu, connect at launch, and "the first connection" fallbacks:
    /// saved records only, in the user's order.
    static func listed(_ all: [ConnectionConfig]) -> [ConnectionConfig] {
        all.filter(\.saved)
    }

    /// The tab pop-up: Open Files first (not-saved records that a tab in ANY
    /// window uses, plus this tab's own record), then the saved servers, then
    /// the saved DuckDB records. Each group keeps the user's order; an empty
    /// group is left out.
    static func popUpSections(_ all: [ConnectionConfig], inUse: Set<String>,
                              current: String?) -> [(section: Section, records: [ConnectionConfig])] {
        let open = all.filter { !$0.saved && (inUse.contains($0.id) || $0.id == current) }
        let servers = all.filter { $0.saved && !$0.isDuckDB }
        let files = all.filter { $0.saved && $0.isDuckDB }
        return [(Section.openFiles, open), (.postgres, servers), (.duckdb, files)].filter { !$0.records.isEmpty }
    }

    /// The order to store after the user drags rows in the Connections
    /// Manager, which shows saved records only. The core rewrites the order of
    /// every id it is given and leaves the others alone, so the hidden records
    /// follow the saved ones in their old order rather than keeping positions
    /// that now collide.
    static func reorderedIds(saved newOrder: [String], all: [ConnectionConfig]) -> [String] {
        let moved = Set(newOrder)
        return newOrder + all.map(\.id).filter { !moved.contains($0) }
    }
}
