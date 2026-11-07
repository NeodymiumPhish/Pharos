// Standalone test for AppDataTransferRules (File ▸ Export App Data… and
// File ▸ Import App Data…). Pure Foundation.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private func summary(sessions: Int? = nil, results: Int? = nil, history: Int? = nil,
                     connections: Int? = nil, secrets: Int? = nil) -> AppDataSummary {
    AppDataSummary(version: 1, encrypted: true, locked: false, exportedAt: nil,
                   sessions: sessions, sessionResults: results, history: history,
                   connections: connections, connectionSecrets: secrets, tags: nil, variables: nil)
}

func runTests() {
    let none = AppDataCategories()
    var tagsOnly = AppDataCategories(); tagsOnly.tags = true
    var withConnections = AppDataCategories(); withConnections.connections = true

    // ---- the export form's rules ---------------------------------------
    expect(AppDataTransferRules.exportProblem(categories: none, encrypt: false, password: "", confirmation: "")
           == .nothingChosen, "an export of nothing is refused")
    expect(AppDataTransferRules.exportProblem(categories: tagsOnly, encrypt: false, password: "", confirmation: "")
           == nil, "an unencrypted export needs no password")
    expect(AppDataTransferRules.exportProblem(categories: withConnections, encrypt: false, password: "",
                                              confirmation: "") == .passwordMissing,
           "connections need a password even with the box clear: they carry passwords")
    expect(AppDataTransferRules.encryptionRequired(withConnections), "connections force encryption")
    expect(!AppDataTransferRules.encryptionRequired(tagsOnly), "tags alone do not")
    expect(AppDataTransferRules.exportProblem(categories: tagsOnly, encrypt: true, password: "short",
                                              confirmation: "short") == .passwordTooShort, "a short password")
    expect(AppDataTransferRules.exportProblem(categories: tagsOnly, encrypt: true, password: "long enough",
                                              confirmation: "long enougH") == .passwordsDiffer, "a mistyped confirmation")
    expect(AppDataTransferRules.exportProblem(categories: withConnections, encrypt: true, password: "long enough",
                                              confirmation: "long enough") == nil, "a good password")

    // ---- the file name ---------------------------------------------------
    let date = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26 UTC
    expect(AppDataTransferRules.defaultFileName(on: date, timeZone: TimeZone(identifier: "UTC")!)
           == "Pharos Data 2026-10-26.pharosdata", "the default file name carries the date")

    // ---- the words ---------------------------------------------------------
    expect(AppDataTransferRules.sessionsPhrase(1) == "1 Session", "one Session")
    expect(AppDataTransferRules.sessionsPhrase(3) == "3 Sessions", "three Sessions")
    let file = summary(sessions: 4, results: 2, history: 10, connections: 3, secrets: 2)
    expect(AppDataTransferRules.importChoiceDetail(.sessions, in: file) == "4 Sessions, with 2 saved results",
           "Sessions with their results")
    expect(AppDataTransferRules.importChoiceDetail(.connections, in: file) == "3 connections, 2 with saved passwords",
           "connections with their passwords")
    expect(AppDataTransferRules.importChoiceDetail(.history, in: file) == "10 entries", "history entries")
    expect(AppDataTransferRules.importChoiceDetail(.tags, in: file) == "Not in this file",
           "absent is not the same as none")
    expect(AppDataTransferRules.importChoiceDetail(.sessions, in: summary(sessions: 1, results: 0)) == "1 Session",
           "no results, no results clause")

    expect(AppDataTransferRules.outcomeLine(.tags, AppDataCategoryOutcome(added: 2, replaced: 0, skipped: 1))
           == "Tags: 2 added, 1 already here, kept", "zero parts are left out")
    expect(AppDataTransferRules.outcomeLine(.variables, AppDataCategoryOutcome(added: 0, replaced: 0, skipped: 0))
           == "Variables: nothing to import", "an empty category says so")

    let result = ImportAppDataResult(sessions: AppDataCategoryOutcome(added: 1, replaced: 0, skipped: 0),
                                     history: nil, connections: nil,
                                     tags: AppDataCategoryOutcome(added: 0, replaced: 1, skipped: 0),
                                     variables: nil)
    expect(AppDataTransferRules.importSummaryLines(result) == ["Sessions: 1 added", "Tags: 1 replaced"],
           "only imported categories, in the form's order")
    expect(AppDataTransferRules.exportSummaryLines(summary(sessions: 2, history: 1))
           == ["Sessions: 2 Sessions", "Query History: 1 entry"], "the export summary")

    // ---- the wire --------------------------------------------------------
    // The property names ARE the JSON keys the core reads (camelCase, no key
    // strategy). Pin them, so a rename breaks here rather than in the app.
    let options = ImportAppDataOptions(path: "/tmp/x", passphrase: nil, categories: .all, conflict: .keep)
    let json = String(decoding: try! JSONEncoder().encode(options), as: UTF8.self)
    expect(json.contains("\"conflict\":\"keep\""), "the conflict policy's wire spelling")
    expect(json.contains("\"connections\":true"), "the category keys")
    let export = ExportAppDataOptions(path: "/tmp/x", categories: tagsOnly, includeSessionResults: true,
                                      passphrase: "p")
    let exportJSON = String(decoding: try! JSONEncoder().encode(export), as: UTF8.self)
    expect(exportJSON.contains("\"includeSessionResults\":true"), "includeSessionResults key")
    let decoded = try? JSONDecoder().decode(AppDataSummary.self, from: Data("""
        {"version":1,"encrypted":true,"locked":true,"exportedAt":null,"sessions":null,"sessionResults":null,
         "history":null,"connections":null,"connectionSecrets":null,"tags":null,"variables":null}
        """.utf8))
    expect(decoded?.locked == true, "a locked summary decodes")
    let present = AppDataCategories.present(in: summary(sessions: 0, history: 5))
    expect(present.sessions && present.history && !present.tags, "zero Sessions still counts as present")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
