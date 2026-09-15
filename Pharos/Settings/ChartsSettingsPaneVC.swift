import AppKit
import Combine
import SwiftUI

/// Settings ▸ Charts. Hosts the SwiftUI palette editor.
///
/// The editor writes into `ChartPaletteModel`, so this pane watches the model
/// rather than any control: every colour well, add and remove reaches
/// `AppSettings.charts.palette` through the same one-field save as the other
/// panes. A colour well drags out a continuous stream of colours, so the writes
/// are coalesced behind a short pause.
final class ChartsSettingsPaneVC: SettingsPaneVC {

    private let paletteModel = ChartPaletteModel(palette: [])
    private var hostingView: NSHostingView<ChartPaletteEditor>!
    private var paletteObserver: AnyCancellable?

    override func loadView() {
        hostingView = NSHostingView(rootView: ChartPaletteEditor(model: paletteModel))
        // The editor sets its own width, and the inset takes it up to the
        // shared minimum so the window keeps ONE width across all four panes.
        view = SettingsForm.wrap(hostingView, inset: 10)
        populate()
        preferredContentSize = SettingsWindowController.paneSize(for: view)

        paletteObserver = paletteModel.$palette
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] palette in
                guard let self else { return }
                self.apply { $0.charts.palette = palette }
                // Adding or removing a slot makes the editor taller or
                // shorter; the window follows it.
                self.preferredContentSize = SettingsWindowController.paneSize(for: self.view)
            }
    }

    override func reloadFromSettings() { populate() }

    private func populate() {
        let stored = stateManager.settings.charts.palette
        guard stored != paletteModel.palette else { return }
        populating { paletteModel.palette = stored }
    }

    /// The editor's own controls are SwiftUI's, and SwiftUI manages their tab
    /// order itself. There is no AppKit chain to assert here.
    override func wireKeyLoop() {
        view.window?.initialFirstResponder = nil
    }
}
