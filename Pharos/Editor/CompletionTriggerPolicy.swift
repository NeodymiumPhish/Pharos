import Foundation

// `CompletionTrigger` itself lives in `Pharos/Models/Settings.swift`, beside
// every other settings enum, so that file keeps compiling with Foundation
// alone for `scripts/test-settings-decode.sh`.

/// The one decision "does the completion list open here?", with no AppKit in
/// it, so `scripts/test-completion-trigger-policy.sh` can check it directly.
///
/// The caller supplies the facts; this type holds no state and reads no
/// settings of its own.
enum CompletionTriggerPolicy {

    /// Whether an automatic completion should be offered.
    ///
    /// - Parameters:
    ///   - trigger: the user's setting.
    ///   - minimumCharacters: how much of an identifier must be typed before
    ///     the identifier trigger fires. Held at 1 or more.
    ///   - prefix: the identifier characters already typed before the caret.
    ///   - precedingCharacter: the character immediately before the caret, or
    ///     nil at the start of the document.
    ///   - isInStringOrComment: whether the caret sits inside a string
    ///     literal or a comment. Nothing is ever offered there.
    static func shouldOffer(
        trigger: CompletionTrigger,
        minimumCharacters: Int,
        prefix: String,
        precedingCharacter: Character?,
        isInStringOrComment: Bool
    ) -> Bool {
        // A string literal and a comment are prose, not code: a completion
        // list over them would be noise, and accepting one would corrupt the
        // text. This gate comes first so no trigger can get past it.
        if isInStringOrComment { return false }

        switch trigger {
        case .off:
            return false
        case .afterDot:
            return precedingCharacter == "."
        case .afterDotAndIdentifiers:
            if precedingCharacter == "." { return true }
            // The prefix is what would be matched. Too short a prefix matches
            // most of the schema, so the list would open on almost every key.
            return prefix.count >= max(1, minimumCharacters)
        }
    }
}
