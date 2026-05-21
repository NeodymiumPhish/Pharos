import Foundation

/// Atomic UTF-8 writer for text files. Used by every save-as-SQL surface so
/// failure handling stays in one place.
enum SQLFileWriter {

    /// Writes `text` to `url` atomically as UTF-8.
    ///
    /// Throws the underlying `NSError` from `Data.write` on failure (caller
    /// shows the alert).
    static func write(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: [.atomic])
    }
}
