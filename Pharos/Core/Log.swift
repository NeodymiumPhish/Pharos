import OSLog

/// The app's unified-logging handles.
///
/// One `Logger` per area of the app, all under the bundle identifier, so a
/// developer can watch exactly one of them:
///
///     log stream --predicate 'subsystem == "com.pharos.client"' --level debug
///     log stream --predicate 'subsystem == "com.pharos.client" AND category == "query"'
///
/// `Logger` is preferred over `NSLog` throughout: it is not formatted unless
/// something is reading, it keeps the category and the level, and it redacts a
/// non-literal string in the public log unless the call site says otherwise.
/// Interpolate a value the user may see — a message from the server, a table
/// name — as `\(value, privacy: .public)` only when it is not their data.
enum Log {

    /// The bundle identifier, so the subsystem follows a renamed bundle rather
    /// than going stale. It is also what the isolated test copies use, which is
    /// why a `log stream` on the identifier finds the copy under test.
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.pharos.client"

    /// Running, cancelling and paging queries, and the results they carry.
    static let query = Logger(subsystem: subsystem, category: "query")

    /// Schema metadata: the browser tree, the caches, table details.
    static let schema = Logger(subsystem: subsystem, category: "schema")

    /// Windows, view controllers, and everything else on screen.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// The Swift side of the C FFI: decoding, callbacks, lifecycle.
    static let ffi = Logger(subsystem: subsystem, category: "ffi")

    /// Signpost intervals for the paths whose cost is worth measuring: the
    /// execute, the two fetch paths, the JSON decode, and the grid reload.
    ///
    /// Intervals are free when nothing is recording, so they stay in the
    /// shipping build. Watch them with:
    ///
    ///     log stream --predicate 'subsystem == "com.pharos.client"' --signpost
    ///
    /// or open the same process in Instruments' os_signpost track.
    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")
}
