import Foundation

/// Which editor tabs the user should be warned about before they are lost, and
/// the words the warning uses.
///
/// Pure and Foundation-only: the same decision serves the three places work can
/// disappear — closing a tab, closing a window, quitting the app — so the three
/// cannot drift apart over what counts as unsaved, and a harness can pose every
/// combination without a window server. See `scripts/test-unsaved-work-policy.sh`.
///
/// The rule (plan §5.2 L):
///
///  * A tab is unsaved when it is DIRTY and it is BOUND to something — a saved
///    query or a file. Its edits have somewhere to go and have not gone there.
///  * A dirty SCRATCH tab — bound to neither — counts only while **Restore open
///    tabs** is OFF. With restore on it comes back at the next launch with its
///    text intact, so warning about it would be a lie.
///  * An empty tab never counts, however dirty. Deleting the last character of
///    a scratch tab is not work worth a dialog.
enum UnsavedWorkPolicy {

    /// As much of a `QueryTab` as the decision needs. Deliberately not the tab
    /// itself: the policy must stay Foundation-only and testable.
    struct Tab: Equatable {
        let id: String
        let name: String
        let isDirty: Bool
        /// `savedQueryId != nil`.
        let hasSavedQuery: Bool
        /// `sourceURL != nil`.
        let hasFile: Bool
        /// The tab's SQL is empty once trimmed.
        let isEmpty: Bool

        init(id: String, name: String, isDirty: Bool, hasSavedQuery: Bool, hasFile: Bool, isEmpty: Bool) {
            self.id = id
            self.name = name
            self.isDirty = isDirty
            self.hasSavedQuery = hasSavedQuery
            self.hasFile = hasFile
            self.isEmpty = isEmpty
        }
    }

    /// Tabs whose loss the user should be warned about, in the order given.
    static func unsaved(in tabs: [Tab], restoreOpenTabs: Bool) -> [Tab] {
        tabs.filter { isUnsaved($0, restoreOpenTabs: restoreOpenTabs) }
    }

    /// The rule itself, for one tab.
    static func isUnsaved(_ tab: Tab, restoreOpenTabs: Bool) -> Bool {
        guard tab.isDirty, !tab.isEmpty else { return false }
        if tab.hasSavedQuery || tab.hasFile { return true }
        // A scratch tab: only at risk when nothing will bring it back.
        return !restoreOpenTabs
    }

    /// Whether a tab's edits can be written back without asking the user where
    /// — which is what the alert's **Save** button promises. True for exactly
    /// the bound tabs; a scratch tab needs the Save Query sheet.
    static func canSaveInPlace(_ tab: Tab) -> Bool {
        tab.hasSavedQuery || tab.hasFile
    }

    // MARK: - Alert text

    /// The alert's message. One tab is named; several are counted, because a
    /// title is one line and eight tab names are not.
    static func alertTitle(for tabs: [Tab]) -> String {
        if tabs.count == 1 {
            return String(localized: "Do you want to save the changes you made to “\(tabs[0].name)”?")
        }
        return String(localized: "You have \(tabs.count) tabs with unsaved changes.")
    }

    /// The line under the message. With several tabs it also lists them, so
    /// **Don't Save** is never a blind choice.
    static func alertMessage(for tabs: [Tab]) -> String {
        let warning = String(localized: "Your changes will be lost if you don't save them.")
        guard tabs.count > 1 else { return warning }
        let names = tabs.map { "• \($0.name)" }.joined(separator: "\n")
        return warning + "\n\n" + names
    }

    /// The **Save** button's title. It says "Save All" for several tabs, the
    /// way every other macOS app does.
    static func saveButtonTitle(for tabs: [Tab]) -> String {
        tabs.count == 1 ? String(localized: "Save") : String(localized: "Save All")
    }

    static let dontSaveButtonTitle = String(localized: "Don't Save")
    static let cancelButtonTitle = String(localized: "Cancel")
}
