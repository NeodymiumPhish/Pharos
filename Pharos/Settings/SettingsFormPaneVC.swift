import AppKit
import Combine

/// A Settings pane described by `sections`. Subclasses override `sections`
/// and nothing else; the builder makes the furniture and the scroll view.
///
/// The pane refreshes from the store on every appearance and on every
/// published settings change — but a control the user is typing in is left
/// alone, or the republishing store would eat the field being edited.
@MainActor
class SettingsFormPaneVC: SettingsPaneVC {

    let paneId: SettingsPaneID
    let builder = SettingsFormBuilder()
    private var settingsCancellable: AnyCancellable?

    init(paneId: SettingsPaneID) {
        self.paneId = paneId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// The pane's content. Bindings must read the CURRENT settings on every
    /// `get`, which `SettingsBinding.settings(_:)` does.
    var sections: [SettingsSection] { [] }

    /// Views stacked ABOVE the first section — a pane that opens with a hero
    /// rather than with a row. Empty for every pane but About.
    ///
    /// A hero is not a section: it has no header, no plate and no rows, so it
    /// cannot be described as a `SettingsSection`. It needs no container of
    /// its own either, because `SettingsFormScroll.makePane` stacks whatever
    /// views it is given with the pane's insets and spacing. Read once, in
    /// `loadView`, like `sections`.
    var headerViews: [NSView] { [] }

    override func loadView() {
        builder.isPopulating = { [unowned self] in self.isPopulating }
        let sectionViews = builder.buildSectionViews(sections, paneId: paneId.rawValue)
        view = SettingsFormScroll.makePane(sections: headerViews + sectionViews)
        view.setAccessibilityIdentifier("settings.form.\(paneId.rawValue)")
        reloadFromSettings()

        settingsCancellable = stateManager.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromSettings() }
    }

    override func reloadFromSettings() {
        populating { builder.refreshAll() }
    }

    /// Straight off `sections`, so what is searchable is exactly what is on
    /// screen. Reading `sections` builds no views.
    override func searchEntries(paneTitle: String) -> [SettingsSearchEntry] {
        SettingsSearchIndex.entries(for: sections, paneId: paneId.rawValue, paneTitle: paneTitle)
    }

    override func reveal(itemId: String) {
        // Reading `view` first: the builder's rows do not exist until
        // `loadView` has run, and a search can send the user to a pane that
        // has never been shown.
        loadViewIfNeeded()
        guard let row = builder.row(for: itemId) else { return }
        // A little above the row, so it does not land hard against the
        // toolbar with its section header out of sight.
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -SettingsMetrics.sectionSpacing))
        if let control = builder.control(for: itemId) as? NSControl, control.acceptsFirstResponder {
            view.window?.makeFirstResponder(control)
        }
    }
}
