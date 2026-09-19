import Foundation

// `KeywordCase` itself lives in `Pharos/Models/Settings.swift`, beside every
// other settings enum.

/// Puts a keyword into the case the user asked for. Pure, so
/// `scripts/test-completion-trigger-policy.sh` checks it without AppKit.
enum KeywordCasing {

    /// `keyword` in the requested case.
    ///
    /// - Parameters:
    ///   - keyword: the completion's canonical text, as the keyword list
    ///     spells it.
    ///   - case: the user's setting.
    ///   - typed: what the user has typed of this word so far. Read only by
    ///     `matchTyping`.
    static func applied(_ keyword: String, case style: KeywordCase, typed: String) -> String {
        switch style {
        case .upper:
            return keyword.uppercased()
        case .lower:
            return keyword.lowercased()
        case .matchTyping:
            // Digits and underscores say nothing about case, so only letters
            // are counted. No letters at all — an empty prefix, `_` — leaves
            // the keyword as the list spells it.
            let letters = typed.filter { $0.isLetter }
            guard !letters.isEmpty else { return keyword }
            if letters.allSatisfy({ $0.isUppercase }) { return keyword.uppercased() }
            if letters.allSatisfy({ $0.isLowercase }) { return keyword.lowercased() }
            // Mixed case ("Sel") is not a request for either, so the keyword
            // keeps its canonical form.
            return keyword
        }
    }
}
