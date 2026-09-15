import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private func text(_ payload: QuickLookItemBuilder.Payload) -> String {
    String(data: payload.data, encoding: .utf8) ?? "<not utf8>"
}

func runTests() {

    // MARK: - JSON

    let obj = QuickLookItemBuilder.payload(value: "{\"b\":1,\"a\":[1,2]}", typeName: "jsonb")
    expect(obj.fileExtension == "json", "jsonb object → .json")
    expect(text(obj) == """
    {
      "a" : [
        1,
        2
      ],
      "b" : 1
    }
    """, "jsonb is pretty-printed with sorted keys and the nesting expanded")

    let nested = QuickLookItemBuilder.payload(
        value: "{\"z\":{\"y\":2,\"x\":1},\"a\":1}", typeName: "json")
    // Sorting is RECURSIVE: the inner object's keys are ordered too, which is
    // what makes two dumps of the same document comparable by eye.
    expect(text(nested).contains("\"x\" : 1"), "nested object is emitted")
    if let xAt = text(nested).range(of: "\"x\""), let yAt = text(nested).range(of: "\"y\"") {
        expect(xAt.lowerBound < yAt.lowerBound, "nested keys are sorted too")
    } else {
        failures += 1
        print("FAIL nested keys are sorted too (keys missing)")
    }

    let arr = QuickLookItemBuilder.payload(value: "[2,1]", typeName: "json")
    expect(arr.fileExtension == "json", "a top-level array is JSON as well")
    expect(text(arr) == "[\n  2,\n  1\n]", "array order is preserved — only KEYS sort")

    let slashes = QuickLookItemBuilder.payload(
        value: "{\"u\":\"https://example.com/a\"}", typeName: "jsonb")
    expect(text(slashes).contains("https://example.com/a"),
           "slashes are not escaped — \\/ is valid JSON and unreadable")

    let broken = QuickLookItemBuilder.payload(value: "{not json", typeName: "jsonb")
    expect(broken.fileExtension == "txt", "unparseable JSON falls back to .txt")
    expect(text(broken) == "{not json", "the fallback keeps the value verbatim")

    let scalar = QuickLookItemBuilder.payload(value: "42", typeName: "jsonb")
    expect(scalar.fileExtension == "txt", "a JSON scalar is text, not a one-line .json file")

    let textJSON = QuickLookItemBuilder.payload(value: " {\"a\":1} ", typeName: "text")
    expect(textJSON.fileExtension == "json", "a text column holding a document is pretty-printed")
    let varcharJSON = QuickLookItemBuilder.payload(value: "[1]", typeName: "character varying")
    expect(varcharJSON.fileExtension == "json", "character varying counts as text-like")

    // The type gate bites: the same string in a non-text column is left alone.
    // Without the gate this would be .json, so the case discriminates.
    let numericLooksLikeJSON = QuickLookItemBuilder.payload(value: "[1,2]", typeName: "int4range")
    expect(numericLooksLikeJSON.fileExtension == "txt",
           "a non-text column is never parsed as JSON")

    expect(QuickLookItemBuilder.payload(value: "{\"a\":1}", typeName: "JSONB").fileExtension == "json",
           "the type name is matched case-insensitively (the header holds it upper-cased)")

    // MARK: - bytea

    let png = QuickLookItemBuilder.payload(value: "\\x89504e470d0a1a0a0000000d", typeName: "bytea")
    expect(png.fileExtension == "png", "bytea with a PNG magic number → .png")
    expect(Array(png.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47],
           "the bytes are the DECODED image, not the hex text")
    expect(png.data.count == 12, "every hex pair decodes to one byte")

    expect(QuickLookItemBuilder.payload(value: "\\xffd8ffe000104a46", typeName: "bytea")
        .fileExtension == "jpg", "JPEG is sniffed")
    expect(QuickLookItemBuilder.payload(value: "\\x474946383961", typeName: "bytea")
        .fileExtension == "gif", "GIF is sniffed")
    expect(QuickLookItemBuilder.payload(value: "\\x255044462d312e34", typeName: "bytea")
        .fileExtension == "pdf", "PDF is sniffed")
    // "RIFF" + a 4-byte size + "WEBP": the size bytes must be SKIPPED, so a
    // signature that only checked a prefix cannot pass this.
    expect(QuickLookItemBuilder.payload(value: "\\x52494646a4010000574542505650", typeName: "bytea")
        .fileExtension == "webp", "WebP is sniffed past the RIFF length field")
    expect(QuickLookItemBuilder.payload(value: "\\x52494646a401000041424344", typeName: "bytea")
        .fileExtension == "bin", "RIFF that is not WEBP is not claimed as WebP")

    let unknownBytes = QuickLookItemBuilder.payload(value: "\\xdeadbeef", typeName: "bytea")
    expect(unknownBytes.fileExtension == "bin", "unrecognised bytes → .bin")
    expect(Array(unknownBytes.data) == [0xDE, 0xAD, 0xBE, 0xEF], "…still decoded")

    expect(QuickLookItemBuilder.payload(value: "\\xABCDEF", typeName: "bytea").data.count == 3,
           "upper-case hex digits decode")

    let escapeForm = QuickLookItemBuilder.payload(value: "\\001\\002abc", typeName: "bytea")
    expect(escapeForm.fileExtension == "txt", "escape-format bytea → .txt")
    expect(text(escapeForm) == "\\001\\002abc", "…showing the text the server sent")

    expect(QuickLookItemBuilder.payload(value: "\\xabc", typeName: "bytea").fileExtension == "txt",
           "an odd digit count is not decoded half-way")
    expect(QuickLookItemBuilder.payload(value: "\\xzz", typeName: "bytea").fileExtension == "txt",
           "a non-hex digit rejects the whole value rather than dropping a byte")
    expect(QuickLookItemBuilder.hexDecoded("\\x") == Data(), "an empty hex bytea decodes to no bytes")
    expect(QuickLookItemBuilder.hexDecoded("89504e47") == nil, "the \\x prefix is required")

    // MARK: - NULL and plain text

    let null = QuickLookItemBuilder.payload(value: nil, typeName: "text")
    expect(null.fileExtension == "txt" && text(null) == "NULL", "NULL previews as the text NULL")
    let nullJSON = QuickLookItemBuilder.payload(value: nil, typeName: "jsonb")
    expect(text(nullJSON) == "NULL", "a NULL json cell is NULL, not an empty document")
    let nullBytea = QuickLookItemBuilder.payload(value: nil, typeName: "bytea")
    expect(nullBytea.fileExtension == "txt" && text(nullBytea) == "NULL",
           "a NULL bytea is not an empty file")

    let empty = QuickLookItemBuilder.payload(value: "", typeName: "text")
    expect(empty.fileExtension == "txt" && text(empty) == "",
           "an empty string is an empty file — it is not NULL")

    let plain = QuickLookItemBuilder.payload(value: "héllo\nwörld", typeName: "text")
    expect(plain.fileExtension == "txt", "plain text → .txt")
    expect(text(plain) == "héllo\nwörld", "non-ASCII text round-trips as UTF-8")

    // MARK: - File names

    expect(QuickLookItemBuilder.fileName(columnName: "email", index: 0, fileExtension: "txt")
        == "email-0.txt", "the plain case is <column>-<index>.<ext>")
    expect(QuickLookItemBuilder.sanitizedName("a/b") == "a_b", "a slash cannot reach the path")
    expect(QuickLookItemBuilder.sanitizedName("../../etc/passwd") == "etc_passwd",
           "a traversal attempt collapses to a flat name")
    expect(QuickLookItemBuilder.sanitizedName("first name") == "first_name", "a space becomes _")
    expect(QuickLookItemBuilder.sanitizedName("a  b") == "a_b", "a run of fillers collapses to one")
    expect(QuickLookItemBuilder.sanitizedName("a\nb") == "a_b", "a newline cannot reach the name")
    expect(QuickLookItemBuilder.sanitizedName("a:b") == "a_b", "a colon (a path separator to Finder) goes")
    expect(QuickLookItemBuilder.sanitizedName("  ") == "value", "a name of only fillers has a fallback")
    expect(QuickLookItemBuilder.sanitizedName("") == "value", "so does an empty one")
    expect(QuickLookItemBuilder.sanitizedName("sum-2") == "sum-2", "- and _ survive")
    expect(QuickLookItemBuilder.sanitizedName(String(repeating: "x", count: 200)).count == 60,
           "a long name is capped")

    // MARK: - Writing and cleaning up

    let builder = QuickLookItemBuilder()
    expect(builder.sessionDirectory.deletingLastPathComponent().path
        == QuickLookItemBuilder.rootDirectory.path,
           "a session folder sits directly under Pharos/QuickLook")
    expect(QuickLookItemBuilder.rootDirectory.path.hasPrefix(NSTemporaryDirectory()),
           "…and the root is inside the temporary directory")

    do {
        let jsonURL = try builder.makeItem(value: "{\"b\":1,\"a\":2}", columnName: "pay load",
                                           typeName: "jsonb", index: 3)
        expect(jsonURL.lastPathComponent == "pay_load-3.json", "the written file is named for the column")
        let written = (try? String(contentsOf: jsonURL, encoding: .utf8)) ?? ""
        expect(written == "{\n  \"a\" : 2,\n  \"b\" : 1\n}", "the file holds the pretty-printed document")

        let binURL = try builder.makeItem(value: "\\x89504e47", columnName: "blob",
                                          typeName: "bytea", index: 4)
        expect(binURL.lastPathComponent == "blob-4.png", "the sniffed extension reaches the file name")
        expect((try? Data(contentsOf: binURL)) == Data([0x89, 0x50, 0x4E, 0x47]),
               "the file holds the decoded bytes")

        // Two cells of the same column differ by index, so neither overwrites
        // the other.
        let a = try builder.makeItem(value: "1", columnName: "n", typeName: "int4", index: 0)
        let b = try builder.makeItem(value: "2", columnName: "n", typeName: "int4", index: 1)
        expect(a != b, "two cells of one column get two files")

        let contents = try FileManager.default.contentsOfDirectory(
            at: builder.sessionDirectory, includingPropertiesForKeys: nil)
        expect(contents.count == 4, "four writes, four files")

        builder.cleanUp()
        expect(!FileManager.default.fileExists(atPath: builder.sessionDirectory.path),
               "cleanUp() removes the session folder")
    } catch {
        failures += 1
        print("FAIL writing a Quick Look item threw: \(error)")
    }

    // The static clean-up takes the whole tree, including a session folder some
    // other panel left behind.
    do {
        let orphan = QuickLookItemBuilder()
        _ = try orphan.makeItem(value: "x", columnName: "c", typeName: "text", index: 0)
        expect(FileManager.default.fileExists(atPath: orphan.sessionDirectory.path),
               "the orphan session exists before the sweep")
        QuickLookItemBuilder.cleanUp()
        expect(!FileManager.default.fileExists(atPath: QuickLookItemBuilder.rootDirectory.path),
               "the static cleanUp() removes the whole Pharos/QuickLook folder")
        expect(FileManager.default.fileExists(atPath: NSTemporaryDirectory()),
               "…and nothing above it")
    } catch {
        failures += 1
        print("FAIL the orphan-session sweep threw: \(error)")
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
    if failures > 0 { exit(1) }
}
