import Foundation

/// The rules and the words of File ▸ Export App Data… and File ▸ Import App
/// Data…, apart from the window so `scripts/test-app-data-transfer.sh` can
/// check them without AppKit.
enum AppDataTransferRules {

    /// The extension of an export. The file is JSON inside.
    static let fileExtension = "pharosdata"

    /// The shortest password the export form accepts.
    static let minimumPasswordLength = 8

    /// Connections are written with their passwords, so a file that holds
    /// them is always encrypted: the form turns encryption on and locks it.
    static func encryptionRequired(_ categories: AppDataCategories) -> Bool {
        categories.connections
    }

    enum ExportProblem: Equatable {
        case nothingChosen
        case passwordMissing
        case passwordTooShort
        case passwordsDiffer
    }

    /// Why the export form cannot go ahead, or nil when it can.
    static func exportProblem(categories: AppDataCategories, encrypt: Bool,
                              password: String, confirmation: String) -> ExportProblem? {
        if categories.isEmpty { return .nothingChosen }
        guard encrypt || encryptionRequired(categories) else { return nil }
        if password.isEmpty { return .passwordMissing }
        if password.count < minimumPasswordLength { return .passwordTooShort }
        if password != confirmation { return .passwordsDiffer }
        return nil
    }

    static func message(for problem: ExportProblem) -> String {
        switch problem {
        case .nothingChosen:
            return String(localized: "Choose at least one kind of data to export.")
        case .passwordMissing:
            return String(localized: "Enter a password to encrypt the file with.")
        case .passwordTooShort:
            return String(localized: "Use a password of at least \(minimumPasswordLength) characters.")
        case .passwordsDiffer:
            return String(localized: "The two passwords do not match.")
        }
    }

    /// "Pharos Data 2026-11-07.pharosdata", in the user's time zone.
    static func defaultFileName(on date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "Pharos Data \(day).\(fileExtension)"
    }

    static func sessionsPhrase(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Session") : String(localized: "\(count) Sessions")
    }

    /// "12 Sessions", "40 entries", "3 connections" — the count part of a
    /// category's line.
    static func countPhrase(_ category: AppDataCategory, _ count: Int) -> String {
        switch category {
        case .sessions: return sessionsPhrase(count)
        case .history: return CountedNounText.phrase(count, "entry")
        case .connections: return CountedNounText.phrase(count, "connection")
        case .tags: return CountedNounText.phrase(count, "tag")
        case .variables: return CountedNounText.phrase(count, "variable")
        }
    }

    /// What the import form shows beside a category's checkbox: what the file
    /// holds of it, or that it holds none.
    static func importChoiceDetail(_ category: AppDataCategory, in summary: AppDataSummary) -> String {
        guard let count = category.count(in: summary) else {
            return String(localized: "Not in this file")
        }
        var text = countPhrase(category, count)
        if category == .sessions, let results = summary.sessionResults, results > 0 {
            text += String(localized: ", with \(CountedNounText.phrase(results, "saved result"))")
        }
        if category == .connections, let secrets = summary.connectionSecrets, secrets > 0 {
            text += String(localized: ", \(secrets) with saved passwords")
        }
        return text
    }

    /// "Sessions: 3 added, 1 replaced, 2 kept". Parts that are zero are left
    /// out; a category where nothing changed says so.
    static func outcomeLine(_ category: AppDataCategory, _ outcome: AppDataCategoryOutcome) -> String {
        var parts: [String] = []
        if outcome.added > 0 { parts.append(String(localized: "\(outcome.added) added")) }
        if outcome.replaced > 0 { parts.append(String(localized: "\(outcome.replaced) replaced")) }
        if outcome.skipped > 0 { parts.append(String(localized: "\(outcome.skipped) already here, kept")) }
        let detail = parts.isEmpty ? String(localized: "nothing to import") : parts.joined(separator: ", ")
        return "\(categoryName(category)): \(detail)"
    }

    /// The short name of a category, for a summary line.
    static func categoryName(_ category: AppDataCategory) -> String {
        switch category {
        case .sessions: return String(localized: "Sessions")
        case .history: return String(localized: "Query History")
        case .connections: return String(localized: "Connections")
        case .tags: return String(localized: "Tags")
        case .variables: return String(localized: "Variables")
        }
    }

    /// One line per imported category, in the form's order.
    static func importSummaryLines(_ result: ImportAppDataResult) -> [String] {
        AppDataCategory.allCases.compactMap { category in
            category.outcome(in: result).map { outcomeLine(category, $0) }
        }
    }

    /// One line per exported category, in the form's order.
    static func exportSummaryLines(_ summary: AppDataSummary) -> [String] {
        AppDataCategory.allCases.compactMap { category in
            category.count(in: summary).map { "\(categoryName(category)): \(countPhrase(category, $0))" }
        }
    }
}
