import AppKit

/// The detail side of the Settings window: the current pane, and nothing
/// else. The surface is the grey the grouped boxes sit on.
///
/// The navigation row that used to sit at the top of this view has moved into
/// the window's toolbar (`SettingsToolbarController`), so the pane now starts
/// at the safe-area top — below the title bar, with no furniture of its own in
/// between.
final class SettingsDetailVC: NSViewController {

    private let paneContainer = NSView()
    private var currentPane: NSViewController?

    override func loadView() {
        let surface = SettingsPaneSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        view = surface

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paneContainer)
        NSLayoutConstraint.activate([
            // The window's top, NOT the safe area: the pane's scroll view
            // insets ITSELF by the title bar (automaticallyAdjustsContentInsets),
            // so the content scrolls UNDER the toolbar and the titlebar
            // separator appears only once it does. Pinning here to the safe
            // area as well would inset the same 52 pt twice.
            paneContainer.topAnchor.constraint(equalTo: view.topAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Swap the pane in. The key view loop is recalculated so Tab walks the
    /// new pane's controls in reading order.
    func show(_ pane: NSViewController) {
        guard currentPane !== pane else { return }
        if let old = currentPane {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
        currentPane = pane
        view.window?.recalculateKeyViewLoop()
    }

    var pane: NSViewController? { currentPane }
}

/// The detail surface. Drawn, not a layer colour, so the dynamic colour is
/// resolved at draw time for the current appearance.
final class SettingsPaneSurfaceView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        SettingsMetrics.paneSurfaceColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
