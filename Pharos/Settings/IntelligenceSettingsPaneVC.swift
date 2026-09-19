import AppKit
import Combine

/// Settings ▸ Intelligence. The Apple Intelligence master switch.
///
/// The row is usable only where the model can run. When it cannot, the
/// reason replaces the caption instead of describing features the user
/// cannot have. It asks `systemModelIsAvailable`, not `isAvailable`: a user
/// who cleared the switch must still be able to set it again.
final class IntelligenceSettingsPaneVC: SettingsFormPaneVC {

    private var availabilityCancellable: AnyCancellable?

    init() { super.init(paneId: .intelligence) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Apple Intelligence"), items: [
                SettingsItem(
                    id: "appleIntelligence",
                    title: String(localized: "Use Apple Intelligence features"),
                    caption: String(localized: "Explain errors, suggest names and charts, draft SQL and summarise plans with the on-device model. Nothing leaves this Mac."),
                    icon: "sparkles",
                    kind: .toggle(.settings(\.useAppleIntelligence)),
                    availability: {
                        let availability = ModelAvailability.shared
                        if availability.systemModelIsAvailable { return .available }
                        return .unavailable(reason: availability.unavailableReason
                            ?? String(localized: "Apple Intelligence is not available on this Mac right now."))
                    }),
            ]),
        ]
    }

    override func loadView() {
        super.loadView()
        availabilityCancellable = ModelAvailability.shared.$systemModelIsAvailable
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromSettings() }
    }

    override func reloadFromSettings() {
        ModelAvailability.shared.refresh()
        super.reloadFromSettings()
    }
}
