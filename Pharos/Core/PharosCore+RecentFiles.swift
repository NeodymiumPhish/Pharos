import Foundation
import CPharosCore

// MARK: - Recent files (the sidebar's Files navigator)
//
// Swift side of pharos-core/src/ffi/recent_files.rs. The keys are
// `RecentFile`'s camelCase property names, matching the core's
// `rename_all = "camelCase"`; `JSONEncoder.pharos` applies no key strategy.

extension PharosCore {

    /// Every recent file, newest first.
    static func loadRecentFiles() throws -> [RecentFile] {
        try callSync { pharos_load_recent_files() }
    }

    /// Note files as opened. An entry keeps the newer of its stored time and
    /// the given one.
    static func touchRecentFiles(_ files: [RecentFile]) throws {
        try callSyncVoid(input: files) { pharos_touch_recent_files($0) }
    }

    /// Remove paths from the list. Files and connection records are untouched.
    static func removeRecentFiles(paths: [String]) throws {
        try callSyncVoid(input: paths) { pharos_remove_recent_files($0) }
    }
}
