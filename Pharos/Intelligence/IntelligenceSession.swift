import AppKit

/// The three pieces every Apple Intelligence feature needs before it opens a
/// session: the availability check, the consent sheet for row data, and the
/// instruction sentences they all share.

// MARK: - Errors

enum IntelligenceError: LocalizedError {
    /// The model cannot be used right now. The string is the user-readable
    /// reason from `ModelAvailability`.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        }
    }
}

// MARK: - Guard

/// The one check every feature makes before it talks to the model.
///
/// A feature that skips it gets a `FoundationModels` error deep inside its own
/// work, at a point where it has nothing useful to tell the user.
enum IntelligenceGuard {

    @MainActor
    static func requireAvailable() throws {
        let availability = ModelAvailability.shared
        guard availability.isAvailable else {
            throw IntelligenceError.unavailable(
                availability.unavailableReason
                    ?? String(localized: "Apple Intelligence is not available right now."))
        }
    }
}

// MARK: - Consent

/// Asks before a feature shows the model the user's ROW data.
///
/// The line is drawn at the data, not at the model. A feature that reads only
/// schema metadata — table and column names, types, a query plan — never calls
/// this. Anything that puts cell values in a prompt must, every time it is
/// invoked: the model runs on this Mac, but the user still gets to say whether
/// their rows are read at all.
@MainActor
final class RowDataConsent {

    /// Returns true when the user chose Continue.
    ///
    /// `what` names what will be read, as a noun phrase that starts a sentence
    /// — "The 20 rows on screen", "The selected cell".
    static func confirm(what: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Send row data to the on-device model?")
        alert.informativeText = String(
            localized: "\(what) will be read by the model on this Mac. Nothing leaves this Mac.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard let window else {
            // No window to hang a sheet on — a menu-driven path, or a test.
            return alert.runModal() == .alertFirstButtonReturn
        }
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn
    }
}

// MARK: - Instructions

/// The sentences every feature puts at the top of its instructions. A feature
/// appends its own after these; none of them replaces them.
enum IntelligenceInstructions {

    /// The model writes text and nothing else. It cannot run anything — Pharos
    /// never executes what comes back — but a suggestion that DROPs a table is
    /// still a suggestion the user might paste and run, so the model is told
    /// not to make one.
    static let sqlSafety = """
        You help a PostgreSQL analyst. Never propose DROP, DELETE, TRUNCATE, \
        ALTER or UPDATE statements. Do not run anything; you only write text.
        """
}
