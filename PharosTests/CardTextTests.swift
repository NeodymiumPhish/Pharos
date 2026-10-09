// Live runner for card text. Links the real Rust staticlib; needs no
// database. Compiled by scripts/test-card-text.sh.
import Foundation
import CPharosCore

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private let border = String(repeating: "=", count: 69)

private func testNotesRoundTrip() {
    var doc = CardDocument()
    let a = doc.cards[0].id
    doc.updateSQL(cardId: a, "WITH params AS (SELECT 1)\nSELECT * FROM params")
    doc.rename(cardId: a, name: "New JA4T Fingerprints")
    doc.setNotes(cardId: a, "Q8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2.")
    let b = doc.insertCard(after: a, sql: "SELECT 2")

    let text = CardText.text(of: doc)
    let expected = "-- name: New JA4T Fingerprints\n/*\n\(border)\nQ8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2.\n\(border)\n*/\nWITH params AS (SELECT 1)\nSELECT * FROM params;\n\nSELECT 2;\n"
    expect(text == expected, "text: the notes block under the name", "got:\n\(text)")

    let back = CardText.document(from: text)
    expect(back.cards.count == 2, "split: two cards")
    expect(back.cards[0].notes == "Q8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2.", "split: notes come back",
           "\(String(describing: back.cards[0].notes))")
    expect(back.cards[0].sql == "WITH params AS (SELECT 1)\nSELECT * FROM params", "split: the SQL without the block")
    expect(back.cards[1].notes == nil, "split: a card without notes has none")
    expect(back.cards.allSatisfy { $0.offersCommentImport == nil }, "split: no import offer from a split alone")
    _ = b

    // Blank notes are not written.
    var blank = CardDocument()
    blank.updateSQL(cardId: blank.cards[0].id, "SELECT 1")
    blank.setNotes(cardId: blank.cards[0].id, "  \n ")
    expect(CardText.text(of: blank) == "SELECT 1;\n", "text: blank notes write nothing")
}

private func testVersionsShareNotes() {
    let text = "-- name: Q\n-- version: 1 locked\n-- SELECT 1\n\n-- name: Q\n-- version: 2\n/*\n\(border)\nabout Q\n\(border)\n*/\nSELECT 2;\n"
    let doc = CardText.document(from: text)
    expect(doc.cards.count == 2 && doc.cards[0].lineageId == doc.cards[1].lineageId, "versions: one query")
    expect(doc.cards.allSatisfy { $0.notes == "about Q" }, "versions: every version has the notes")
    expect(CardText.text(of: doc) == text, "versions: the text round-trips", CardText.text(of: doc))
}

private func testPersistenceFallbackKeepsNotes() {
    var doc = CardDocument()
    let a = doc.cards[0].id
    doc.updateSQL(cardId: a, "SELECT 1")
    doc.setNotes(cardId: a, "why")
    let stored = CardPersistence.encode(doc)
    let fromJSON = CardPersistence.decode(json: stored.json, text: stored.text)
    expect(fromJSON == doc, "persistence: JSON keeps the document")
    let fromText = CardPersistence.decode(json: nil, text: stored.text)
    expect(fromText.cards[0].notes == "why" && fromText.cards[0].sql == "SELECT 1", "persistence: the text fallback keeps the notes")
}

private func testExtract() {
    let sql = """
    -- =========================================================================
    -- Q8. NEW TCP CLIENT FINGERPRINTS (JA4T) FROM THE HONEYPOT
    -- The honeypot OS normally makes one or few JA4T values.
    -- =========================================================================
    WITH params AS (
        SELECT 1 -- CHANGE: honeypot IP
    )
    SELECT * FROM params
    """
    let got = PharosCore.extractLeadingNotes(sql)
    expect(got?.notes == "Q8. NEW TCP CLIENT FINGERPRINTS (JA4T) FROM THE HONEYPOT\nThe honeypot OS normally makes one or few JA4T values.",
           "extract: the notes", String(describing: got))
    expect(got?.sql == "WITH params AS (\n    SELECT 1 -- CHANGE: honeypot IP\n)\nSELECT * FROM params", "extract: the SQL from its first token")
    expect(PharosCore.extractLeadingNotes("SELECT 1") == nil, "extract: nothing to take")
    expect(PharosCore.extractLeadingNotes("/* a */\nSELECT 1")?.notes == "a", "extract: a block comment")
}

private func testFileImportOffers() {
    let text = "-- name: Q8\n-- ====\n-- Why Q8\n-- ====\nSELECT 1;\n\nSELECT 2;\n\n-- only a comment\n;\n\n/*\n\(border)\nmine\n\(border)\n*/\nSELECT 3;\n"
    let doc = CardText.document(fromFile: text)
    expect(doc.cards.count == 4, "file: four cards", "\(doc.cards.map(\.sql))")
    guard doc.cards.count == 4 else { return }
    expect(doc.cards[0].offersCommentImport == true && doc.cards[0].name == "Q8", "file: leading comments offer the import")
    expect(doc.cards[1].offersCommentImport == nil, "file: no comments, no offer")
    expect(doc.cards[2].offersCommentImport == nil, "file: a comment-only card, no offer")
    expect(doc.cards[3].offersCommentImport == nil && doc.cards[3].notes == "mine", "file: Pharos notes are notes, no offer")
    expect(CardText.document(from: text).cards.allSatisfy { $0.offersCommentImport == nil }, "file: other callers never offer")
}

private func testVariableTokensInNotes() {
    let ip = QueryVariable(name: "ip", value: "10.0.0.1")

    // Import keeps the tokens: the comment import and the notes block.
    let extracted = PharosCore.extractLeadingNotes("-- Set {{ip}} to the honeypot\nSELECT {{ip}}::inet")
    expect(extracted?.notes == "Set {{ip}} to the honeypot" && extracted?.sql == "SELECT {{ip}}::inet",
           "tokens: the comment import keeps them", String(describing: extracted))
    let read = CardText.document(fromFile: "/*\n\(border)\nSet {{ip}} first\n\(border)\n*/\nSELECT {{ip}};\n")
    expect(read.cards.first?.notes == "Set {{ip}} first" && read.cards.first?.sql == "SELECT {{ip}}",
           "tokens: a notes block keeps them")

    // Export renders the SQL and keeps the notes' tokens.
    var doc = CardDocument()
    let a = doc.cards[0].id
    doc.updateSQL(cardId: a, "SELECT {{ip}}::inet")
    doc.setNotes(cardId: a, "Set {{ip}} to the honeypot")
    let out = CardText.renderedText(of: doc, variables: [ip])
    expect(out.contains("Set {{ip}} to the honeypot") && out.contains("SELECT 10.0.0.1::inet") && !out.contains("SELECT {{ip}}"),
           "tokens: export renders the SQL, not the notes", out)

    // A saved Session: with notes, the same rule; without, the stored text
    // renders as it always did (here: no `;` is added).
    let stored = CardPersistence.encode(doc, mode: .latest)
    let session = CardText.renderedText(storedSQL: stored.text, cardsJson: stored.json, variables: [ip])
    expect(session == out, "tokens: a Session with notes exports the same", session)
    let fromTextOnly = CardText.renderedText(storedSQL: stored.text, cardsJson: nil, variables: [ip])
    expect(fromTextOnly == out, "tokens: a Session with no JSON reads its notes from the text", fromTextOnly)
    let plain = CardText.renderedText(storedSQL: "SELECT {{ip}}", cardsJson: nil, variables: [ip])
    expect(plain == "SELECT 10.0.0.1", "tokens: a Session without notes is unchanged", plain)
}

func runTests() {
    testVariableTokensInNotes()
    testFileImportOffers()
    testNotesRoundTrip()
    testVersionsShareNotes()
    testPersistenceFallbackKeepsNotes()
    testExtract()
    if failures == 0 { print("\nAll CardText tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
