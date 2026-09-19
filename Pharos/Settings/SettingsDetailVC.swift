import AppKit

/// The detail side of the Settings window: the header row and the current
/// pane's view below it. The surface is the grey the grouped boxes sit on.
final class SettingsDetailVC: NSViewController {

    let header = SettingsDetailHeaderView()
    private let paneContainer = NSView()
    private var currentPane: NSViewController?

    override func loadView() {
        let surface = SettingsPaneSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        view = surface

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(paneContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Swap the pane in and refresh the header. The key view loop is
    /// recalculated so Tab walks the new pane's controls in reading order.
    func show(_ pane: NSViewController, title: String, canGoBack: Bool, canGoForward: Bool) {
        if currentPane !== pane {
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
        }
        header.update(title: title, canGoBack: canGoBack, canGoForward: canGoForward)
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
