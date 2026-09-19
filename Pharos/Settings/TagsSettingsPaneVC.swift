import AppKit
import SwiftUI

/// Settings ▸ Tags. The tag colour palette, and how a tagged row is drawn.
///
/// The palette editor is the same SwiftUI view the Charts pane hosts, over a
/// different model, so the two stay in step by construction rather than by
/// being kept alike.
final class TagsSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .tags) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Rows"), items: [
                SettingsItem(
                    id: "maximumColourSegments",
                    title: String(localized: "Colour bands per row"),
                    caption: String(localized: "How many tag colours the bar at the left edge of a row may show. A row with more tags is not hiding them: the tooltip and the Inspector always list every one."),
                    icon: "square.stack.3d.up",
                    kind: .stepper(.settings(\.tags.maximumColourSegments), range: 1...6,
                                   unit: String(localized: "bands"))),
                SettingsItem(
                    id: "cellTintOpacity",
                    title: String(localized: "Cell tint"),
                    caption: String(localized: "How strongly a matched cell is washed with its tag's colour. The wash always stays lighter than the find match you are looking at, so the two can be told apart."),
                    icon: "drop",
                    kind: .slider(.settings(\.tags.cellTintOpacity), range: 0.05...0.6)),
            ]),
        ]
    }
}
