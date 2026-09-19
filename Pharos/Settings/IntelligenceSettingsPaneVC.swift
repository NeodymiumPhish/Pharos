import AppKit
import Combine

/// Settings ▸ Intelligence. The Apple Intelligence master switch, the seven
/// features under it, and what the thumbs have recorded.
///
/// The master row is usable only where the model can run. When it cannot, the
/// reason replaces the caption instead of describing features the user
/// cannot have. It asks `systemModelIsAvailable`, not `isAvailable`: a user
/// who cleared the switch must still be able to set it again.
///
/// Each feature row `dependsOn` the master, so clearing the master dims all
/// seven at once rather than leaving a column of switches that do nothing.
/// The switches themselves are only stored preferences; the rule that turns
/// them into an answer lives in `ModelAvailability.isAvailable(for:)`, which
/// every feature site asks.
final class IntelligenceSettingsPaneVC: SettingsFormPaneVC {

    private var availabilityCancellable: AnyCancellable?

    init() { super.init(paneId: .intelligence) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Most ratings the caption counts. The store keeps more; a settings
    /// caption does not need them, and a pane refresh must not read the whole
    /// table.
    static let feedbackSampleLimit = 500

    /// "12 helpful, 3 not helpful" — or why the count could not be read.
    ///
    /// Recomputed on every refresh, because a rating given in another window
    /// while this pane is open must show up when the user comes back to it.
    private func feedbackCaption() -> String {
        do {
            let entries = try PharosCore.loadModelFeedback(limit: Self.feedbackSampleLimit)
            guard !entries.isEmpty else {
                return String(localized: "Nothing rated yet. The thumbs under a generated answer are recorded here.")
            }
            let helpful = entries.filter { $0.rating > 0 }.count
            let notHelpful = entries.count - helpful
            return String(localized: "\(helpful) helpful, \(notHelpful) not helpful. Kept on this Mac, and never sent anywhere.")
        } catch {
            return String(localized: "The ratings could not be read.")
        }
    }

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
                SettingsItem(
                    id: "describeQuery",
                    title: String(localized: "Describe the query"),
                    caption: String(localized: "The editor toolbar button that drafts SQL from a sentence."),
                    icon: "text.bubble",
                    kind: .toggle(.settings(\.intelligence.describeQuery)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "allowDraftingWriteStatements",
                    title: String(localized: "Allow drafts that write"),
                    caption: String(localized: "Off drafts reads only: a draft that is not a plain SELECT is refused instead of offered. Pharos never runs a draft either way."),
                    icon: "exclamationmark.shield",
                    kind: .toggle(.settings(\.intelligence.allowDraftingWriteStatements)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "explainErrors",
                    title: String(localized: "Explain query errors"),
                    caption: String(localized: "The explanation block on the query-error sheet."),
                    icon: "exclamationmark.bubble",
                    kind: .toggle(.settings(\.intelligence.explainErrors)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "summarisePlans",
                    title: String(localized: "Summarise query plans"),
                    caption: String(localized: "A sentence above an EXPLAIN result saying what the planner chose."),
                    icon: "list.bullet.rectangle",
                    kind: .toggle(.settings(\.intelligence.summarisePlans)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "suggestCharts",
                    title: String(localized: "Suggest charts"),
                    caption: String(localized: "Off, \u{201C}Suggest chart\u{201D} still applies the chart Pharos recommends for these columns."),
                    icon: "chart.xyaxis.line",
                    kind: .toggle(.settings(\.intelligence.suggestCharts)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "suggestSavedQueryNames",
                    title: String(localized: "Suggest names"),
                    caption: String(localized: "Fills the name field in the Save Query sheet and the rename dialogs. You can always type your own."),
                    icon: "textformat",
                    kind: .toggle(.settings(\.intelligence.suggestSavedQueryNames)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "nameTabsAutomatically",
                    title: String(localized: "Name tabs automatically"),
                    caption: String(localized: "Renames a tab still called \u{201C}Query 1\u{201D} from its SQL the first time it runs. A tab you have named is never touched."),
                    icon: "rectangle.and.pencil.and.ellipsis",
                    kind: .toggle(.settings(\.intelligence.nameTabsAutomatically)),
                    dependsOn: "appleIntelligence"),
            ]),
            SettingsSection(title: String(localized: "Feedback"), items: [
                SettingsItem(
                    id: "feedbackCounts",
                    title: String(localized: "Ratings you have given"),
                    dynamicCaption: { [weak self] in self?.feedbackCaption() ?? "" },
                    icon: "hand.thumbsup",
                    kind: .display),
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
