import Foundation

/// The rows of the sidebar's Files navigator, in its three sections.
///
/// - **Open**: in-memory DuckDB databases that are open, and files whose
///   record is connected or used by a tab.
/// - **Recent**: the other files opened in the last `olderThanDays` days,
///   newest first.
/// - **Older**: the rest, newest first.
///
/// Pure (`scripts/test-files-list-rule.sh`): the caller gives it the stored
/// list, the records, which records are open, a path → record lookup and the
/// time now.
enum FilesListRule {
    enum Section: Equatable {
        case open, recent, older
    }

    struct Row: Equatable {
        enum Kind: Equatable {
            case database, data, memory
        }

        /// The path, or "memory:<record id>" for an in-memory database.
        let id: String
        /// Nil for an in-memory database.
        let path: String?
        let title: String
        /// The folder, `~` for home; nil for an in-memory database.
        let folder: String?
        let kind: Kind
        /// The DuckDB record on this file (or the in-memory record), if any.
        let recordId: String?
        let saved: Bool
        let isOpen: Bool
        let lastOpened: Date?
    }

    static let defaultOlderThanDays = 60

    static func sections(files: [RecentFile], records: [ConnectionConfig], openRecordIds: Set<String>,
                         recordForPath: (String) -> ConnectionConfig?, now: Date,
                         olderThanDays: Int = defaultOlderThanDays) -> [(section: Section, rows: [Row])] {
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        var open: [Row] = [], recent: [Row] = [], older: [Row] = []
        for file in files {
            let record = file.kind == RecentFile.Kind.duckdb.rawValue ? recordForPath(file.path) : nil
            let isOpen = record.map { openRecordIds.contains($0.id) } ?? false
            let url = file.url
            let row = Row(id: file.path, path: file.path,
                          title: url.lastPathComponent,
                          folder: ConnectionConfig.abbreviatingHome(url.deletingLastPathComponent().path),
                          kind: file.kind == RecentFile.Kind.data.rawValue ? .data : .database,
                          recordId: record?.id, saved: record?.saved ?? false, isOpen: isOpen,
                          lastOpened: file.lastOpened)
            if isOpen {
                open.append(row)
            } else if let date = row.lastOpened, date >= cutoff {
                recent.append(row)
            } else {
                older.append(row)
            }
        }
        // In-memory databases have no file: they come from their records,
        // after the open files.
        for record in records where record.isInMemoryDuckDB && openRecordIds.contains(record.id) {
            open.append(Row(id: "memory:\(record.id)", path: nil, title: record.name, folder: nil, kind: .memory,
                            recordId: record.id, saved: record.saved, isOpen: true, lastOpened: nil))
        }
        // The store is newest first already; keep that order in each section.
        return [(Section.open, open), (.recent, recent), (.older, older)].filter { !$0.rows.isEmpty }
    }

    /// Remove from List also forgets a NOT saved record when nothing else
    /// holds it: no saved Session refers to it and no open tab uses it. A
    /// saved file, or one a Session or tab uses, loses only its list entry.
    static func forgetsRecord(_ row: Row, sessionConnectionIds: Set<String>, tabConnectionIds: Set<String>) -> Bool {
        guard let id = row.recordId, !row.saved, row.kind == .database else { return false }
        return !sessionConnectionIds.contains(id) && !tabConnectionIds.contains(id)
    }
}
