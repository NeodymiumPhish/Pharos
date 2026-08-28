import Foundation

/// The one rule for what a result-tab rename commits.
///
/// A result tab's name is normally derived from its query — `L1-3: users` — and
/// follows the statement as the editor text moves. `ResultTab.customLabel`
/// overrides that, permanently, so committing one is a decision and not just a
/// text assignment. Two typed strings must therefore mean "no override":
///
/// - **Empty.** Clearing the field is the only way back to the derived name,
///   so it has to be a supported answer rather than a refused one.
/// - **Exactly the derived name.** The rename dialog prefills with the name on
///   screen, so a user who opens it and presses Rename without typing would
///   otherwise freeze `L1-3: users` as a custom name and the tab would silently
///   stop tracking its statement. Nothing the user did says they wanted that.
///
/// Pure, and free of AppKit and of the model layer, so
/// `scripts/test-result-tab-name.sh` can compile it on its own.
enum ResultTabName {

    /// The custom name a rename commits, or `nil` to restore the derived name.
    ///
    /// - Parameters:
    ///   - typed: the raw contents of the rename field.
    ///   - automatic: the tab's derived name (`ResultTab.automaticLabel`).
    static func committed(_ typed: String, automatic: String) -> String? {
        // `AuthoredLabelSanitizer.committed` is the single producer for every
        // authored label on its way to the store: it denies entry to the
        // scalars that let a name misrepresent itself, then trims. Sanitise
        // BEFORE comparing with `automatic` — otherwise a name padded with a
        // no-break space reads as different here and identical on screen.
        let name = AuthoredLabelSanitizer.committed(typed)
        if name.isEmpty { return nil }
        if name == automatic { return nil }
        return name
    }
}
