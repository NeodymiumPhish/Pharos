import Foundation

// MARK: - TagCommitError

/// What a save reports when the thing it was written to is not there any more.
///
/// The core cannot report this for itself. `update_tag` runs
/// `UPDATE … WHERE id = ?1` and answers `Ok(None)` for an id that is gone, and
/// `update_tag_rule` answers `Ok(0)` — successes, both of them, as far as the
/// FFI's one error channel is concerned. The absence has to be turned into a
/// failure on this side or it is not a failure at all.
enum TagCommitError: LocalizedError, CustomStringConvertible, Equatable {
    /// The tag an update named has been deleted — in another window, most
    /// likely, while the Tag Manager sat open on it.
    case tagVanished
    /// The rule an edit named has been deleted the same way.
    case ruleVanished

    var errorDescription: String? { message }

    /// Kept after the sheet moved to `localizedDescription`, for the channels
    /// that still interpolate: the `NSLog` line beside the save, and anything
    /// that prints an error without asking for its description. An enum that is
    /// only a `LocalizedError` interpolates as its case name, so without this
    /// those lines would read "tagVanished" — a Swift identifier, not a
    /// sentence.
    var description: String { message }

    private var message: String {
        switch self {
        case .tagVanished:
            return "That tag no longer exists. "
                + "It may have been deleted in another window."
        case .ruleVanished:
            return "That rule no longer exists. "
                + "It may have been deleted in another window."
        }
    }
}

// MARK: - TagCommitWriting

/// The six store writes one save needs.
///
/// Named exactly as `TagStore` already names them, so the store conforms with
/// no glue at all — and so a change to any of their signatures fails the APP
/// build rather than drifting away from what a save expects.
///
/// Deliberately nonisolated, like `TagManagerCommitting` and `TagRuleRemoving`:
/// it exists so a headless harness can drive the real save loop below without
/// `TagStore` — which is `@MainActor` and reaches the macOS Keychain through the
/// FFI — coming into the binary with it.
protocol TagCommitWriting {
    func createTag(_ create: CreateTag) throws -> Tag
    func updateTag(_ update: UpdateTag) throws -> Tag?
    func addTuples(_ payload: AddTagRules) throws -> Int
    func updateRule(_ payload: UpdateTagRule) throws -> Bool
    func removeTuples(ids: [String]) throws
    func deleteTag(id: String) throws
}

extension TagCommitWriting {

    /// Apply one save.
    ///
    /// This IS `TagStore.apply(_:)` — the store conforms to
    /// `TagManagerCommitting` with this method as the witness, so there is no
    /// second copy for a harness to test instead of the real one.
    ///
    /// Each command goes through the store's ordinary methods, which re-read
    /// after every write rather than applying a hand-made delta: the core mints
    /// ids and absorbs duplicate rules, so only a re-read is honest about what
    /// was stored. That means several reloads for a multi-command save, which is
    /// acceptable because a save is a deliberate act and not a keystroke.
    ///
    /// # Which answers are failures
    ///
    /// Two of the six writes answer "there was nothing by that id", and the two
    /// are decided differently — on what the analyst asked for, not on the shape
    /// of the answer.
    ///
    /// An UPDATE that found nothing is a failure. The analyst changed a name, a
    /// colour, a note or a rule's conditions, and none of it was written; a
    /// silent success there closes the sheet on work that no longer exists
    /// anywhere. That is the case the manage sheet this manager replaced checked
    /// by hand, and the check came back here with it.
    ///
    /// A DELETE that found nothing is NOT a failure. The analyst asked for the
    /// tag or the rule to be gone and it is gone; who removed it changes
    /// nothing about the outcome, and refusing the save would leave them staring
    /// at an error about a thing they wanted destroyed. `addTuples` returning
    /// fewer than it was given is the same kind of answer for the same reason —
    /// a duplicate tuple is absorbed by the unique index, which is the
    /// re-tagging no-op and has always been correct.
    func apply(_ commits: [TagManagerCommit]) throws {
        for commit in commits {
            switch commit {
            case .create(let payload):
                _ = try createTag(payload)
            case .update(let payload):
                guard try updateTag(payload) != nil else {
                    throw TagCommitError.tagVanished
                }
            case .addRules(let payload):
                _ = try addTuples(payload)
            case .updateRule(let payload):
                // False means no row carried that id. It cannot mean "the row
                // was already like that": `commits()` only emits an update when
                // the conditions differ, and SQLite counts a matched row as
                // changed either way.
                guard try updateRule(payload) else {
                    throw TagCommitError.ruleVanished
                }
            case .deleteRules(let ids):
                try removeTuples(ids: ids)
            case .deleteTag(let id):
                try deleteTag(id: id)
            }
        }
    }
}
