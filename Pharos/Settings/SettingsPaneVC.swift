import AppKit

/// Shared scaffolding for the panes of the Settings window.
///
/// The window has no Save button: every control writes its one field into
/// `AppSettings` and persists it the moment it changes. That is what the base
/// class exists for.
///
///  - `apply` reads the CURRENT published settings, mutates the one field the
///    control owns and saves. It never writes a whole snapshot taken when the
///    pane was built, so two panes cannot overwrite each other's fields.
///  - Buttons, popups, radios and steppers commit on their action.
///  - Text fields commit after a short typing pause, and immediately when
///    editing ends (Tab, Return, or the field losing focus). Without the pause
///    a three-digit row limit would be saved three times, the first two of them
///    as truncated numbers.
///  - `populating` suppresses the writes that setting a control's value
///    triggers, so refreshing a pane from the store never writes back to it.
@MainActor
class SettingsPaneVC: NSViewController, NSTextFieldDelegate {

    let stateManager = AppStateManager.shared

    /// Live typing is written after this long a pause.
    private let textCommitDelay: TimeInterval = 0.3

    private(set) var isPopulating = false
    private var pendingCommits: [ObjectIdentifier: Timer] = [:]

    // MARK: - Applying

    /// Persist one change. The mutation is applied to the settings as they
    /// stand right now, not to a copy held by the pane.
    func apply(_ mutate: (inout AppSettings) -> Void) {
        guard !isPopulating else { return }
        let current = stateManager.settings
        var updated = current
        mutate(&updated)
        guard updated != current else { return }
        stateManager.saveSettings(updated)
    }

    /// Run `body` with writes suppressed — for putting stored values INTO the
    /// controls, which fires their actions.
    func populating(_ body: () -> Void) {
        isPopulating = true
        body()
        isPopulating = false
    }

    /// Refresh every control from the store. Called when the window is shown.
    func reloadFromSettings() {}

    /// Wire this pane's explicit key view loop and name its first control.
    /// Called every time the pane appears, because `NSTabViewController`
    /// re-manages the loop when it swaps panes in.
    func wireKeyLoop() {}

    // MARK: - Text fields

    /// Subclasses write `field`'s value into the settings. Called after the
    /// typing pause and again when editing ends.
    func commitTextField(_ field: NSTextField) {}

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        scheduleCommit(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        cancelCommit(field)
        guard !isPopulating else { return }
        commitTextField(field)
    }

    private func scheduleCommit(_ field: NSTextField) {
        cancelCommit(field)
        guard !isPopulating else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: textCommitDelay, repeats: false) { [weak self, weak field] _ in
            Task { @MainActor in
                guard let self, let field else { return }
                self.pendingCommits[ObjectIdentifier(field)] = nil
                self.commitTextField(field)
            }
        }
        pendingCommits[ObjectIdentifier(field)] = timer
    }

    private func cancelCommit(_ field: NSTextField) {
        pendingCommits.removeValue(forKey: ObjectIdentifier(field))?.invalidate()
    }

    // MARK: - Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFromSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Same reason the old sheet did this: an NSGridView's automatic key
        // view loop follows its subview order, not the row-by-row reading
        // order, and the tab controller recalculates the loop when it swaps a
        // pane in. Re-assert the explicit chain last.
        view.window?.autorecalculatesKeyViewLoop = false
        wireKeyLoop()
    }

    deinit {
        for (_, timer) in pendingCommits { timer.invalidate() }
    }
}
