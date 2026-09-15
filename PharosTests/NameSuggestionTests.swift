// Standalone test runner for the "suggest a name" feature's two halves that
// do not need the model: what goes in the prompt, and what is accepted back.
//
// Compiled with `NameSuggestionPolicy` and `AuthoredLabelSanitizer` only —
// pure Foundation, no AppKit and no FoundationModels. The model itself cannot
// be exercised here, and would not be worth exercising: it answers differently
// every time. What CAN go wrong deterministically is the prompt (SQL that is
// too long, a folder list that is not sent) and the post-processing (a name
// that is 200 characters, a folder the user does not have, an empty title that
// wipes the field) — and that is all of what is below.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let extra = detail()
        print("FAIL \(name)" + (extra.isEmpty ? "" : "\n  \(extra)"))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    expect(actual == expected, name, "expected: \(expected)\n  actual:   \(actual)")
}

// MARK: - Fixtures

private let shortSQL = "select relkind, count(*) from pg_class group by relkind"
private let folders = ["Reports", "Ad hoc", "Catalogue"]

// MARK: - The prompt

private func testPromptCarriesTheSQL() {
    let prompt = NameSuggestionPolicy.prompt(
        sql: shortSQL, tables: "pg_class", folders: folders, kind: .savedQuery)

    expect(prompt.contains(shortSQL), "prompt carries the SQL verbatim")
    expect(prompt.contains("pg_class"), "prompt carries the table names")
    expect(prompt.contains("Reports") && prompt.contains("Ad hoc") && prompt.contains("Catalogue"),
           "prompt lists every folder")
    expect(!prompt.contains(NameSuggestionPolicy.truncationMarker),
           "a short statement is not marked as truncated")
}

private func testPromptWithoutFoldersSaysSo() {
    let prompt = NameSuggestionPolicy.prompt(
        sql: shortSQL, tables: nil, folders: [], kind: .editorTab)
    expect(prompt.contains("Folders: none"), "an empty folder list is stated, not omitted")
    expect(prompt.contains("editor tab"), "the prompt says which list the name is for")
}

private func testPromptCapsTheSQL() {
    // 4,000 characters, twice the cap, with a marker at each end so the test
    // can tell the head was kept and the tail dropped.
    let long = "select 1 -- HEAD\n" + String(repeating: "x", count: 4000) + "\n-- TAIL"
    let prompt = NameSuggestionPolicy.prompt(
        sql: long, tables: nil, folders: [], kind: .savedQuery)

    expect(prompt.contains("HEAD"), "the start of a long statement survives the cap")
    expect(!prompt.contains("TAIL"), "the end of a long statement is dropped by the cap")
    expect(prompt.contains(NameSuggestionPolicy.truncationMarker),
           "a capped statement is marked as truncated")
    expectEqual(NameSuggestionPolicy.cappedSQL(long).count,
                NameSuggestionPolicy.maxSQLLength + NameSuggestionPolicy.truncationMarker.count,
                "the capped statement is exactly the cap plus the marker")
}

// MARK: - The answer: the title

private func testTitleIsTitleCasedAndTrimmed() {
    expectEqual(NameSuggestionPolicy.title(from: "  recent orders by region  ", fallback: "Query 1"),
                "Recent Orders By Region", "a lower-case answer is title-cased and trimmed")
    expectEqual(NameSuggestionPolicy.title(from: "\"Relation Kind Counts\"", fallback: "Query 1"),
                "Relation Kind Counts", "wrapping quotes are removed")
    expectEqual(NameSuggestionPolicy.title(from: "Relation Kind Counts.", fallback: "Query 1"),
                "Relation Kind Counts", "a trailing full stop is removed")
    expectEqual(NameSuggestionPolicy.title(from: "counts   by    relkind", fallback: "Query 1"),
                "Counts By Relkind", "runs of whitespace collapse to one space")
}

private func testTitleLeavesIdentifiersAlone() {
    // Only words that are letters through and through are raised. `pg_class`
    // is the object's real name and must still read as it.
    expectEqual(NameSuggestionPolicy.title(from: "counts from pg_class", fallback: "Query 1"),
                "Counts From pg_class", "an identifier keeps its own spelling")
}

private func testTitleIsSanitized() {
    // A right-to-left override in a name displays the rest of it backwards.
    // The field this lands in is one the user can press Save on, so the
    // scalar is denied entry exactly as it is for a typed name.
    let hostile = "safe\u{202E}gpj.exe"
    let title = NameSuggestionPolicy.title(from: hostile, fallback: "Query 1")
    expect(!title.unicodeScalars.contains { $0.value == 0x202E },
           "a bidi override is removed from a suggested name")
    // A zero-width space would make two names that read identically.
    let invisible = NameSuggestionPolicy.title(from: "Rel\u{200B}kind Counts", fallback: "Query 1")
    expect(!invisible.unicodeScalars.contains { $0.value == 0x200B },
           "a zero-width space is removed from a suggested name")
}

private func testTitleIsCappedAtFortyCharacters() {
    let long = "Counts of every relation kind held in the PostgreSQL system catalogue"
    let title = NameSuggestionPolicy.title(from: long, fallback: "Query 1")
    expect(title.count <= NameSuggestionPolicy.maxTitleLength,
           "a long answer is capped at 40 characters", "got \(title.count): \(title)")
    expect(!title.hasSuffix(" "), "the capped name has no trailing space")
    expect(long.hasPrefix(title.prefix(6)), "the capped name is the start of the answer")

    // A single word longer than the cap has no boundary to cut at, so it is
    // cut mid-word rather than being thrown away.
    let oneWord = String(repeating: "a", count: 90)
    expectEqual(NameSuggestionPolicy.title(from: oneWord, fallback: "Query 1").count,
                NameSuggestionPolicy.maxTitleLength, "a single long word is cut to the cap")
}

private func testEmptyTitleFallsBackToTheDefault() {
    expectEqual(NameSuggestionPolicy.title(from: "", fallback: "Query 1"),
                "Query 1", "an empty answer keeps the default name")
    expectEqual(NameSuggestionPolicy.title(from: "   \n  ", fallback: "Query 1"),
                "Query 1", "a whitespace-only answer keeps the default name")
    expectEqual(NameSuggestionPolicy.title(from: "\u{200B}\u{202E}", fallback: "Query 1"),
                "Query 1", "an answer of nothing but removed scalars keeps the default name")
}

// MARK: - The answer: the folder

private func testKnownFolderIsKept() {
    expectEqual(NameSuggestionPolicy.folder(from: "Reports", in: folders),
                "Reports", "a folder from the list is kept")
    expectEqual(NameSuggestionPolicy.folder(from: "  reports ", in: folders),
                "Reports", "the match ignores case and the stored spelling wins")
}

private func testUnknownFolderIsDropped() {
    expectEqual(NameSuggestionPolicy.folder(from: "Invented", in: folders),
                nil, "a folder the user does not have is dropped")
    expectEqual(NameSuggestionPolicy.folder(from: nil, in: folders),
                nil, "no folder stays no folder")
    expectEqual(NameSuggestionPolicy.folder(from: "  ", in: folders),
                nil, "a blank folder is dropped")
    expectEqual(NameSuggestionPolicy.folder(from: "Reports", in: []),
                nil, "with no folders at all, nothing is selected")
}

// MARK: - Entry point

func runTests() {
    testPromptCarriesTheSQL()
    testPromptWithoutFoldersSaysSo()
    testPromptCapsTheSQL()
    testTitleIsTitleCasedAndTrimmed()
    testTitleLeavesIdentifiersAlone()
    testTitleIsSanitized()
    testTitleIsCappedAtFortyCharacters()
    testEmptyTitleFallsBackToTheDefault()
    testKnownFolderIsKept()
    testUnknownFolderIsDropped()

    print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
