import Foundation

/// Writes one result cell's value to a temporary file that Quick Look can
/// preview, and decides what KIND of file that is.
///
/// Every cell crosses the FFI as a text string in PostgreSQL's text format, so
/// the only things this has to work from are that string and the column's
/// declared type. Three rules, in order:
///
/// 1. `json` / `jsonb`, and a text-like column whose value is a JSON object or
///    array, are re-emitted pretty-printed with sorted keys, as `.json`. A
///    value that does not parse falls back to plain text — the preview still
///    shows something rather than an error sheet.
/// 2. `bytea` in PostgreSQL's hex form is decoded and sniffed for a magic
///    number, so a stored PNG previews as an image and not as 40 kB of hex.
///    Unrecognised bytes get `.bin`; the older escape form, which this does not
///    decode, is shown as the text it is.
/// 3. Everything else is UTF-8 text.
///
/// Nothing here touches AppKit, so the rules are unit-testable on their own
/// (`scripts/test-quick-look-item-builder.sh`).
struct QuickLookItemBuilder {

    // MARK: - Locations

    /// The folder every session folder lives in. `cleanUp()` removes this whole
    /// tree, so nothing outside it is ever at risk of deletion.
    static var rootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Pharos", isDirectory: true)
            .appendingPathComponent("QuickLook", isDirectory: true)
    }

    /// This builder's own folder. One per open panel, so closing the panel can
    /// delete everything it wrote without consulting a list of files.
    let sessionDirectory: URL

    init(sessionID: UUID = UUID()) {
        sessionDirectory = Self.rootDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    // MARK: - Payload

    /// The bytes chosen for a value and the extension they should carry.
    /// Separated from the write so the classification can be asserted without a
    /// file system.
    struct Payload: Equatable {
        let data: Data
        let fileExtension: String
    }

    /// What a NULL cell previews as. A NULL is not an empty string and must not
    /// look like one.
    static let nullText = "NULL"

    private static let jsonTypes: Set<String> = ["json", "jsonb"]

    /// Column types whose value is worth TRYING as JSON. A JSON document stored
    /// in a `text` column is common enough to be worth pretty-printing, but the
    /// attempt is confined to types that could plausibly hold one — a `numeric`
    /// or a `timestamp` never gets parsed.
    private static let textLikeTypes: Set<String> = [
        "", "text", "varchar", "character varying", "char", "character",
        "bpchar", "name", "citext", "unknown",
    ]

    static func payload(value: String?, typeName: String) -> Payload {
        guard let value else {
            return Payload(data: Data(nullText.utf8), fileExtension: "txt")
        }
        let type = typeName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if type == "bytea" { return byteaPayload(value) }

        if jsonTypes.contains(type) || textLikeTypes.contains(type),
           let pretty = prettyPrintedJSON(value) {
            return Payload(data: pretty, fileExtension: "json")
        }

        return Payload(data: Data(value.utf8), fileExtension: "txt")
    }

    // MARK: - JSON

    /// Pretty-prints a JSON object or array; nil for anything else.
    ///
    /// Scalars are deliberately excluded: `JSONSerialization` refuses a
    /// top-level fragment without `.fragmentsAllowed`, and a bare `42` or
    /// `"hello"` from a `jsonb` column reads better as text than as a one-line
    /// JSON file. The leading-character check only saves the parse attempt; the
    /// type check after it is what decides.
    static func prettyPrintedJSON(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else { return nil }
        // `.withoutEscapingSlashes` matters for the common case of a URL inside
        // a document: `https:\/\/` is valid JSON and unreadable.
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - bytea

    private static func byteaPayload(_ value: String) -> Payload {
        guard let bytes = hexDecoded(value) else {
            // The escape form (`\001\002…`) is left as the text the server sent.
            // Decoding it is a second, rarer grammar; showing the text is honest
            // and never wrong about what the column holds.
            return Payload(data: Data(value.utf8), fileExtension: "txt")
        }
        return Payload(data: bytes, fileExtension: sniffedExtension(bytes) ?? "bin")
    }

    /// Decodes PostgreSQL's hex `bytea` output (`\x` then hex pairs). Nil for
    /// anything that is not exactly that, including an odd digit count or a
    /// stray non-hex character — a partial decode would be a confident wrong
    /// answer, which is worse than falling back to text.
    static func hexDecoded(_ value: String) -> Data? {
        guard value.hasPrefix("\\x") else { return nil }
        let digits = Array(value.dropFirst(2).utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30              // 0-9
        case 0x61...0x66: return byte - 0x61 + 10         // a-f
        case 0x41...0x46: return byte - 0x41 + 10         // A-F
        default: return nil
        }
    }

    /// Magic-number signatures, in the order they are tried. Only formats
    /// Quick Look renders natively are listed — anything else is `.bin`, which
    /// previews as a file icon and a size rather than as garbage.
    private static let signatures: [(bytes: [UInt8], ext: String)] = [
        ([0x89, 0x50, 0x4E, 0x47], "png"),   // \x89 P N G
        ([0xFF, 0xD8, 0xFF], "jpg"),
        ([0x47, 0x49, 0x46, 0x38], "gif"),   // G I F 8
        ([0x25, 0x50, 0x44, 0x46], "pdf"),   // % P D F
    ]

    static func sniffedExtension(_ data: Data) -> String? {
        for signature in signatures where data.starts(with: signature.bytes) {
            return signature.ext
        }
        // WebP is a RIFF container: "RIFF", a four-byte length, then "WEBP".
        if data.count >= 12,
           data.starts(with: Array("RIFF".utf8)),
           Array(data.dropFirst(8).prefix(4)) == Array("WEBP".utf8) {
            return "webp"
        }
        return nil
    }

    // MARK: - File names

    /// The panel titles itself from the file name, so the name is the column
    /// the value came from. Everything outside `[A-Za-z0-9_-]` (and letters of
    /// other scripts) becomes one underscore: a column name is user data and
    /// can hold a slash, a colon or a newline, none of which may reach a path.
    static func sanitizedName(_ columnName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var out = String.UnicodeScalarView()
        var lastWasFiller = false
        for scalar in columnName.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(scalar)
                lastWasFiller = false
            } else if !lastWasFiller {
                out.append("_")
                lastWasFiller = true
            }
        }
        let trimmed = String(out).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !trimmed.isEmpty else { return "value" }
        // A PostgreSQL identifier can be 63 bytes and a name can come from an
        // expression alias, so cap it well inside any file-name limit.
        return String(trimmed.prefix(60))
    }

    /// `<column>-<index>.<ext>`. The index keeps a multi-cell preview's files
    /// apart when two cells come from the same column.
    static func fileName(columnName: String, index: Int, fileExtension: String) -> String {
        "\(sanitizedName(columnName))-\(index).\(fileExtension)"
    }

    // MARK: - Writing

    /// Writes the value into this session's folder and returns the file.
    @discardableResult
    func makeItem(value: String?, columnName: String, typeName: String, index: Int) throws -> URL {
        let payload = Self.payload(value: value, typeName: typeName)
        try FileManager.default.createDirectory(at: sessionDirectory,
                                                withIntermediateDirectories: true)
        let url = sessionDirectory.appendingPathComponent(
            Self.fileName(columnName: columnName, index: index,
                          fileExtension: payload.fileExtension))
        try payload.data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Clean up

    /// Removes this session's folder and everything in it.
    func cleanUp() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    /// Removes every session folder. Called at quit, so a panel that was open
    /// when the app went away does not leave its files behind.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
