import Foundation

/// Pure helpers for turning saved-query names into safe filesystem filenames
/// and resolving collisions deterministically.
enum SavedQueryFilename {

    /// Sanitize a saved-query name into a safe filesystem stem (no extension).
    ///
    /// - Replaces `/`, `:`, NUL, and ASCII control characters with `_`.
    /// - Strips leading dots so the file isn't hidden.
    /// - Returns `"untitled"` for empty input or input that sanitizes to empty.
    static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":", "\0":
                out.append("_")
            case _ where scalar.value < 0x20:
                out.append("_")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        while out.hasPrefix(".") {
            out.removeFirst()
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// Given a target directory and a desired filename `stem.sql`, return a
    /// unique URL by appending ` (2)`, ` (3)`, … to the stem until no
    /// collision exists. `taken` lets the caller block out filenames that
    /// will be written later in the same batch but don't exist on disk yet.
    static func uniquify(stem: String, in directory: URL, taken: inout Set<String>) -> URL {
        let fm = FileManager.default
        var candidate = "\(stem).sql"
        var n = 2
        while taken.contains(candidate) || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n)).sql"
            n += 1
        }
        taken.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
