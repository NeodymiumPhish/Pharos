import Foundation

/// Pure helpers for turning saved-query names into safe filesystem filenames
/// and resolving collisions deterministically.
enum SavedQueryFilename {

    /// Sanitize a saved-query name into a safe filesystem stem (no extension).
    ///
    /// - Replaces `/`, `:` and NUL with `_`.
    /// - Replaces every scalar `DisplayEscape.mustEscape` names with `_` — the
    ///   whole invisible class: C0 controls, DEL, the C1 range (NEL included),
    ///   bidi marks/overrides/isolates, line and paragraph separators,
    ///   zero-width scalars and the BOM, and the unusual spaces. Replaced
    ///   rather than removed, so the substitution is VISIBLE in the name the
    ///   user is offered in the save panel: removing a bidi override would let
    ///   `safe\u{202E}gpj.exe` quietly become `safegpj.exe`, while `safe_gpj.exe`
    ///   shows that something was taken out. One shared definition means the
    ///   set a label escapes and the set a filename replaces can never drift.
    /// - Strips leading dots so the file isn't hidden.
    /// - Returns `"untitled"` for empty input or input that sanitizes to empty.
    static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":", "\0":
                out.append("_")
            // Every scalar the display escaper names, replaced rather than
            // removed so the substitution is visible in the name the user is
            // offered. The old `< 0x20` bound missed DEL and the whole C1
            // range, which includes NEL.
            // Every scalar the display escaper names, replaced rather than
            // removed so the substitution is visible in the name the user is
            // offered. The old `< 0x20` bound missed DEL and the whole C1
            // range, which includes NEL.
            case _ where DisplayEscape.mustEscape(scalar):
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
