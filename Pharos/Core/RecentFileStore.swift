import AppKit

// MARK: - RecentFileStore

/// The app's copy of the Files navigator's list: every DuckDB database and data
/// file the user opened, with no limit (`recent_files` in the store).
///
/// `note(_:)` is the one way a file is recorded as opened: it notes the system's
/// recent documents too (File ▸ Open Recent, the Dock), which keep only the
/// newest few, so those lists are always the newest part of this one.
///
/// `@MainActor`: every reader is a view controller and every write follows a
/// user action; the FFI calls are synchronous and local (SQLite).
@MainActor
final class RecentFileStore {

    static let shared = RecentFileStore()

    /// Posted after any change to the list, including the first load.
    static let didChange = Notification.Name("PharosRecentFilesDidChange")

    /// Set once the store was seeded from the system's recent documents and the
    /// DuckDB records that existed before the Files navigator.
    private static let seededKey = "RecentFilesSeeded1"

    private init() {}

    private(set) var files: [RecentFile] = []
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        seedOnce()
        reload()
    }

    /// Note files as opened now, here and in the system's recent documents.
    func note(_ urls: [URL]) {
        let now = RecentFile.stamp(Date())
        let entries = urls.filter(\.isFileURL).map { url in
            RecentFile(path: url.path, kind: Self.kind(of: url).rawValue, lastOpenedAt: now)
        }
        for url in urls where url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        guard !entries.isEmpty else { return }
        write { try PharosCore.touchRecentFiles(entries) }
    }

    /// Remove paths from the list. The files, and any connection record on
    /// them, stay; a caller that also forgets a record does that itself.
    func remove(paths: [String]) {
        guard !paths.isEmpty else { return }
        write { try PharosCore.removeRecentFiles(paths: paths) }
    }

    static func kind(of url: URL) -> RecentFile.Kind {
        DataFiles.isDataFile(url) ? .data : .duckdb
    }

    private func write(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.state.error("Recent files: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }

    private func reload() {
        do {
            files = try PharosCore.loadRecentFiles()
        } catch {
            Log.state.error("Failed to load recent files: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Once, at the first load after the upgrade: the system's recent
    /// documents (newest first, one second apart so their order holds) and
    /// every DuckDB file record, which goes in as old (the Older section) when
    /// no recent document names it.
    private func seedOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        let connections = AppStateManager.shared.connections
        let recents = DuckDBFiles.recentFiles(NSDocumentController.shared.recentDocumentURLs, in: connections)
        let now = Date()
        var entries = recents.enumerated().map { index, url in
            RecentFile(path: url.path, kind: Self.kind(of: url).rawValue,
                       lastOpenedAt: RecentFile.stamp(now.addingTimeInterval(-Double(index))))
        }
        let listed = Set(entries.map(\.path))
        let old = RecentFile.stamp(Date(timeIntervalSince1970: 0))
        for record in connections where record.isDuckDB && !record.isInMemoryDuckDB && !listed.contains(record.database) {
            entries.append(RecentFile(path: record.database, kind: RecentFile.Kind.duckdb.rawValue, lastOpenedAt: old))
        }
        do {
            if !entries.isEmpty { try PharosCore.touchRecentFiles(entries) }
            defaults.set(true, forKey: Self.seededKey)
        } catch {
            Log.state.error("Failed to seed recent files: \(error.localizedDescription, privacy: .public)")
        }
    }
}
