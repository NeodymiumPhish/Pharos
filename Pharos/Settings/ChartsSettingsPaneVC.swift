import AppKit
import Combine
import SwiftUI

/// Settings ▸ Charts. Hosts the SwiftUI palette editor inside one group box.
///
/// The editor writes into `ChartPaletteModel`, so this pane watches the model
/// rather than any control: every colour well, add and remove reaches
/// `AppSettings.charts.palette` through the same one-field save as the other
/// panes. A colour well drags out a continuous stream of colours, so the
/// writes are coalesced behind a short pause.
final class ChartsSettingsPaneVC: SettingsFormPaneVC {

    private let paletteModel = ChartPaletteModel(palette: [])
    private var paletteObserver: AnyCancellable?

    init() { super.init(paneId: .charts) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Palette"), items: [
                SettingsItem(
                    id: "palette",
                    title: String(localized: "Series colours"),
                    caption: String(localized: "The default colour for each series. A chart can override it."),
                    icon: "paintpalette",
                    kind: .custom { [paletteModel] in
                        let hosting = NSHostingView(rootView: ChartPaletteEditor(model: paletteModel))
                        // Without this the row collapses to zero height.
                        hosting.sizingOptions = [.intrinsicContentSize]
                        return hosting
                    }),
            ]),
        ]
    }

    override func loadView() {
        super.loadView()
        paletteObserver = paletteModel.$palette
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] palette in
                self?.apply { $0.charts.palette = palette }
            }
    }

    override func reloadFromSettings() {
        super.reloadFromSettings()
        let stored = stateManager.settings.charts.palette
        guard stored != paletteModel.palette else { return }
        populating { paletteModel.palette = stored }
    }
}
