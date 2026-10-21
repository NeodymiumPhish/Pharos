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
}
