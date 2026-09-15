import AppKit
import FoundationModels

/// A name the on-device model proposes for a query, and the folder it would
/// file it under.
///
/// The folder is only meaningful where there is a folder to choose — the Save
/// Query sheet. A tab rename asks for the same structure and ignores it, which
/// is cheaper than two `@Generable` types for one sentence of difference.
@Generable
struct NameSuggestion {

    @Guide(description: "two to four words, Title Case, no punctuation")
    var title: String

    @Guide(description: "an existing folder name from the list, or nil")
    var folder: String?
}

extension NameSuggestion {
    /// Spelled as the brief names it, so a call site reads
    /// `NameSuggestion.Kind.savedQuery`.
    typealias Kind = NameSuggestionKind
}

/// Asks the on-device model for a name.
///
/// One session per call: a name for one statement has nothing to learn from
/// the name of another, and a session held across unrelated queries would
/// carry the earlier SQL in its transcript for no gain.
///
/// Everything this sends is schema — the statement, the tables it mentions and
/// the user's own folder names. No result ever passes through here, so there
/// is nothing for `RowDataConsent` to ask about.
@MainActor
final class NameSuggester {

    /// Suggest a name for `sql`.
    ///
    /// Throws `IntelligenceError.unavailable` when the feature is off or the
    /// model cannot run, and `LanguageModelSession.GenerationError` for the
    /// model's own refusals. A caller that has no way to show an error simply
    /// keeps the name it had.
    func suggest(
        sql: String,
        existingFolders: [String],
        kind: NameSuggestion.Kind
    ) async throws -> NameSuggestion {
        try IntelligenceGuard.requireAvailable()

        let prompt = Self.prompt(sql: sql, existingFolders: existingFolders, kind: kind)
        let session = LanguageModelSession(
            instructions: IntelligenceInstructions.sqlSafety + "\n" + NameSuggestionPolicy.instructions)

        let response = try await session.respond(to: prompt, generating: NameSuggestion.self)

        var suggestion = response.content
        // An empty title falls back to an empty string, not to a default name:
        // only the call site knows what its own default is, and it already
        // shows it. It leaves the field alone when nothing comes back.
        suggestion.title = NameSuggestionPolicy.title(from: suggestion.title, fallback: "")
        suggestion.folder = NameSuggestionPolicy.folder(from: suggestion.folder, in: existingFolders)
        return suggestion
    }

    /// The prompt, built the way `suggest` builds it. Exposed so a call site
    /// can log or hash the same text the model was given.
    static func prompt(sql: String, existingFolders: [String], kind: NameSuggestion.Kind) -> String {
        NameSuggestionPolicy.prompt(
            sql: sql,
            tables: PharosCore.extractTableNames(from: sql),
            folders: existingFolders,
            kind: kind
        )
    }
}
