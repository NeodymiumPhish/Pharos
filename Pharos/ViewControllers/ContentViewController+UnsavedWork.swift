import AppKit

/// The warning that stands between the user and losing an edit they have not
/// written back — plan §5.2 L.
///
/// The DECISION is `UnsavedWorkPolicy`, which is pure and tested on its own.
/// This file is the AppKit half: it poses the window's tabs to the policy,
/// puts the answer in an alert, and does what the user chooses. The three
/// places work can disappear — closing a tab, closing a window, quitting —
/// all come through here, so all three ask the same question in the same words
/// and save by the same path.
extension ContentViewController {

    /// One tab, as the policy sees it.
    func unsavedWorkTab(_ tab: QueryTab) -> UnsavedWorkPolicy.Tab {
        UnsavedWorkPolicy.Tab(
            id: tab.id,
            name: tab.name,
            isDirty: tab.isDirty,
            hasSavedQuery: tab.savedQueryId != nil,
            hasFile: tab.sourceURL != nil,
            // `tab.sql` is current for every tab, not only the visible one:
            // `QueryEditorVC.textDidChange` writes each keystroke into it.
            isEmpty: tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Every tab of THIS window whose loss the user should be warned about.
    ///
    /// The one reader of `session.warnBeforeClosingUnsavedTabs`: with the
    /// setting off this is always empty, so every caller — tab close, window
    /// close, quit — goes back to closing without a word.
    var unsavedWorkTabs: [UnsavedWorkPolicy.Tab] {
        let settings = AppStateManager.shared.settings
        guard settings.session.warnBeforeClosingUnsavedTabs else { return [] }
        return UnsavedWorkPolicy.unsaved(
            in: session.tabs.map(unsavedWorkTab),
            restoreOpenTabs: settings.query.restoreOpenTabs)
    }

    /// The subset of `unsavedWorkTabs` that belongs to one tab — what the tab's
    /// own close button has to ask about.
    func unsavedWorkTabs(forTabId id: String) -> [UnsavedWorkPolicy.Tab] {
        unsavedWorkTabs.filter { $0.id == id }
    }

    /// Ask about `tabs`, then say whether the close may go ahead.
    ///
    /// `then(true)` means proceed — the work was saved, or the user chose to
    /// lose it. `then(false)` means Cancel: nothing closes, nothing is lost.
    /// An empty list answers `true` at once, without a dialog.
    func confirmClosing(_ tabs: [UnsavedWorkPolicy.Tab], then: @escaping (Bool) -> Void) {
        guard !tabs.isEmpty else { then(true); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UnsavedWorkPolicy.alertTitle(for: tabs)
        alert.informativeText = UnsavedWorkPolicy.alertMessage(for: tabs)
        alert.addButton(withTitle: UnsavedWorkPolicy.saveButtonTitle(for: tabs))
        alert.addButton(withTitle: UnsavedWorkPolicy.dontSaveButtonTitle)
        alert.addButton(withTitle: UnsavedWorkPolicy.cancelButtonTitle)
        // Escape is Cancel, and ⌘D is Don't Save — the macOS convention for
        // this dialog. Without the first, Escape would pick the second button.
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = .command
        alert.buttons[2].keyEquivalent = "\u{1b}"

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { then(false); return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveEach(tabs, then: then)
            case .alertSecondButtonReturn:
                then(true)          // Don't Save: close and lose the edits.
            default:
                then(false)         // Cancel, Escape, or a dismissed sheet.
            }
        }

        // A sheet when there is a window to hang it from; otherwise modal, so
        // the completion cannot fail to run. The quit path waits on it with
        // `.terminateLater`, and a completion that never fires would hang the
        // whole quit.
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Save each tab in turn, stopping at the first the user backs out of.
    ///
    /// A BOUND tab (a saved query, a file) is written straight back. A dirty
    /// SCRATCH tab — which only reaches here while **Restore open tabs** is off
    /// — has nowhere to write to, so it gets the Save Query sheet; cancelling
    /// that sheet cancels the close, because the alternative is to close a tab
    /// the user has just declined to save.
    private func saveEach(_ tabs: [UnsavedWorkPolicy.Tab], then: @escaping (Bool) -> Void) {
        guard let head = tabs.first else { then(true); return }
        let rest = Array(tabs.dropFirst())

        if UnsavedWorkPolicy.canSaveInPlace(head) {
            guard saveTabInPlace(id: head.id) else { then(false); return }
            saveEach(rest, then: then)
            return
        }

        guard let tab = session.tabs.first(where: { $0.id == head.id }) else {
            saveEach(rest, then: then)
            return
        }
        // No window, no sheet — and a sheet that never appears would leave a
        // quit waiting on `.terminateLater` for ever. Answer "cancel" instead:
        // nothing closes, and nothing is lost.
        guard view.window != nil else { then(false); return }
        // Bring the tab the sheet is about to the front: a Save Query sheet
        // over somebody else's SQL is worse than no sheet at all.
        session.selectTab(id: tab.id)
        presentSaveQuerySheet(tab: tab) { [weak self] saved in
            guard let self else { then(false); return }
            guard saved else { then(false); return }
            self.saveEach(rest, then: then)
        }
    }
}
