import Foundation
import UniformTypeIdentifiers

/// DuckDB database files: their type, and which connection record opens one.
///
/// A DuckDB file is a connection record, made on demand: opening a file
/// (File ▸ Open DuckDB Database…, the Dock, Finder, Open Recent) finds the
/// record that already names it, or makes one named after the file.
/// Pure apart from the `UTType`, so `scripts/test-duckdb-files.sh` pins it.
enum DuckDBFiles {

    /// Pharos's imported type for `.duckdb` / `.ddb` (`Info.plist`). DuckDB
    /// publishes none of its own.
    static let typeIdentifier = "com.pharos.duckdb-database"
    static let extensions: Set<String> = ["duckdb", "ddb"]

    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(importedAs: typeIdentifier, conformingTo: .database)
    }

    /// Is this a file Pharos opens as a DuckDB database? By extension, so a
    /// file Launch Services has not typed yet still counts.
    static func isDuckDBFile(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    /// The same file, however it was spelled: symlinks resolved, `.` and
    /// `..` gone. `/tmp/x` and `/private/tmp/x` compare equal.
    /// The FOLDER goes through `realpath` (the file may not exist yet, and
    /// `resolvingSymlinksInPath` leaves a missing file's folder alone), which
    /// is also how the core canonicalises it (`db::duckdb::normalized_path`).
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if let real = realpath(url.path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let folder = url.deletingLastPathComponent().path
        guard let realFolder = realpath(folder, nil) else { return url.path }
        defer { free(realFolder) }
        return (String(cString: realFolder) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// The saved DuckDB record that names this file, if there is one. The
    /// first in list order wins, so a file named by two records always opens
    /// with the same one.
    static func record(for path: String, in connections: [ConnectionConfig]) -> ConnectionConfig? {
        let target = canonicalPath(path)
        return connections.first { $0.isDuckDB && !$0.isInMemoryDuckDB && canonicalPath($0.database) == target }
    }

    /// Every DuckDB record that names this file and is open now (`isOpen`:
    /// connected or connecting). File ▸ New refuses such a file: moving it
    /// to the Trash would leave the open tabs writing into the trashed file.
    static func openRecords(for path: String, in connections: [ConnectionConfig],
                            isOpen: (String) -> Bool) -> [ConnectionConfig] {
        let target = canonicalPath(path)
        return connections.filter {
            $0.isDuckDB && !$0.isInMemoryDuckDB && canonicalPath($0.database) == target && isOpen($0.id)
        }
    }

    /// The name for a new record on this file: the file's stem when no other
    /// record has that name, else "stem (folder)", then more folders
    /// ("stem (b/folder)"), then a number ("stem 2"). Names compare trimmed
    /// and case-folded. `excluding`: the record being edited, whose own name
    /// does not count. ~/a/data.duckdb and ~/b/data.duckdb so never share a
    /// name in the pop-up, the Dock menu, a window title or VoiceOver.
    static func uniqueName(forPath path: String, in connections: [ConnectionConfig],
                           excluding id: String? = nil) -> String {
        func key(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let taken = Set(connections.filter { $0.id != id }.map { key($0.name) })
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let stem = url.deletingPathExtension().lastPathComponent
        if !taken.contains(key(stem)) { return stem }
        let folders = url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        var parts: [String] = []
        for folder in folders.reversed() {
            parts.insert(folder, at: 0)
            let candidate = "\(stem) (\(parts.joined(separator: "/")))"
            if !taken.contains(key(candidate)) { return candidate }
        }
        var n = 2
        while taken.contains(key("\(stem) \(n)")) { n += 1 }
        return "\(stem) \(n)"
    }

    /// The Open Recent list: the recent URLs that are DuckDB files (by
    /// extension, or named by a file record, so a `.db` file counts) and the
    /// data files DuckDB read (CSV, JSON, Parquet, Excel).
    static func recentFiles(_ urls: [URL], in connections: [ConnectionConfig]) -> [URL] {
        urls.filter { url in
            url.isFileURL && (isDuckDBFile(url) || DataFiles.isDataFile(url) || record(for: url.path, in: connections) != nil)
        }
    }

    /// Open Recent titles: each file's display name, and " — <folder>" for
    /// names that would otherwise look the same. No full paths (HIG, File
    /// management); the tooltip has the path.
    static func recentTitles(_ urls: [URL], displayName: (URL) -> String) -> [String] {
        let names = urls.map(displayName)
        var counts: [String: Int] = [:]
        for name in names { counts[name.lowercased(), default: 0] += 1 }
        return zip(urls, names).map { url, name in
            guard counts[name.lowercased(), default: 0] > 1 else { return name }
            return "\(name) — \(displayName(url.deletingLastPathComponent()))"
        }
    }

    /// The name for a new in-memory record: "In-memory DuckDB", then
    /// "In-memory DuckDB 2", … — never a name in use (case-folded).
    static func uniqueInMemoryName(in connections: [ConnectionConfig]) -> String {
        let base = String(localized: "In-memory DuckDB")
        let taken = Set(connections.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// The files that make up a database at this path: the file, and its
    /// write-ahead log when there is one. Replacing a database moves both to
    /// the Trash: DuckDB 1.5.6 does not replay a stale `.wal` into a new file
    /// — it deletes it — so a database trashed without its WAL loses the
    /// changes not yet checkpointed (measured 2026-10-21).
    static func databaseFiles(at url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        let wal = URL(fileURLWithPath: url.path + ".wal")
        return [url] + (fileExists(wal.path) ? [wal] : [])
    }
}
