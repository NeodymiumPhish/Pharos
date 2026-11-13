import AppKit
import Combine
import SwiftUI

/// Settings ▸ Intelligence. Which model answers, the master switch, the
/// seven features under it, and what the thumbs have recorded.
///
/// The Model section chooses between Apple's on-device model and a custom
/// endpoint. The endpoint's address, model name and window are settings; its
/// API key goes straight to the Keychain and is never one. The endpoint rows
/// stay usable while Apple Intelligence is chosen, so an endpoint can be
/// entered and tested before anything is switched over to it.
///
/// Nothing is sent to an endpoint on another machine until the user has
/// agreed to that host, in a sheet that says what is sent. Choosing the
/// endpoint asks; so does the Allow button, for an address entered or
/// changed afterwards. The agreement is stored as the host
/// (`endpoint.allowedHost`), and `ModelAvailability` holds every feature
/// off until it matches.
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

    private let keyModel = IntelligenceEndpointKeyModel()

    /// The last Test Connection, with the endpoint it was asked of. Shown
    /// only while the settings still name that endpoint: a result for an
    /// address the user has since changed says nothing about the new one.
    private var lastCheck: (endpoint: IntelligenceEndpointSettings, message: String)?
    private var checkTask: Task<Void, Never>?

    /// The model names the endpoint listed, with the address and key state
    /// they were listed for. Offered under Model name only while the address
    /// is still that one: another endpoint has other models. Held while the
    /// pane is open and never stored.
    private var listedModels: (address: String, names: [String])?

    init() { super.init(paneId: .intelligence) }

    private var endpoint: IntelligenceEndpointSettings { stateManager.settings.intelligence.endpoint }

    // MARK: - Captions

    private func providerCaption() -> String {
        switch stateManager.settings.intelligence.provider {
        case .apple:
            return String(localized: "The model built into macOS. Nothing leaves this Mac.")
        case .endpoint:
            return String(localized: "When a feature runs, your SQL, schema names, table definitions, error messages and query plans go to the endpoint below.")
        }
    }

    /// What is wrong with the address, or where it sends things.
    private func addressCaption() -> String {
        let text = endpoint.baseUrl
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "The API root of an OpenAI-compatible endpoint, such as https://api.example.com/v1 or http://localhost:11434/v1.")
        }
        switch IntelligenceEndpoint.baseURL(from: text) {
        case .failure(let problem):
            return problem.message
        case .success(let url):
            if IntelligenceEndpoint.isOnThisMac(url) {
                return String(localized: "This endpoint is on this Mac.")
            }
            return String(localized: "What Pharos sends this endpoint leaves this Mac and goes to \(url.host ?? text).")
        }
    }

    /// The names to offer under Model name: the endpoint's own, when it has
    /// been asked and the address has not changed since.
    private func modelOptions() -> [String] {
        guard let listedModels, listedModels.address == endpoint.baseUrl else { return [] }
        return listedModels.names
    }

    private func modelCaption() -> String {
        let count = modelOptions().count
        if count > 0 {
            return String(localized: "Pick one of the \(count) models the endpoint lists, or type a name.")
        }
        return String(localized: "The model's name exactly as the endpoint lists it. Press the arrow to list the endpoint's models.")
    }

    private func checkCaption() -> String {
        if let lastCheck, lastCheck.endpoint == endpoint { return lastCheck.message }
        return String(localized: "Asks the endpoint for its list of models, and offers them under Model name. Sends the API key and nothing else.")
    }

    // MARK: - Permission to send

    /// The host that still needs the user's agreement, or nil.
    private func hostNeedingPermission() -> String? {
        guard case .success(let base) = IntelligenceEndpoint.baseURL(from: endpoint.baseUrl) else { return nil }
        return IntelligenceEndpoint.hostNeedingPermission(base: base, allowedHost: endpoint.allowedHost)
    }

    /// The Sending row: the button is live only while there is a host to
    /// agree to, and the sentence beside it says where things stand.
    private func permissionAvailability() -> SettingsAvailability {
        switch IntelligenceEndpoint.baseURL(from: endpoint.baseUrl) {
        case .failure:
            return .unavailable(reason: String(localized: "Enter the endpoint's address first."))
        case .success(let base):
            if IntelligenceEndpoint.isOnThisMac(base) {
                return .unavailable(reason: String(localized: "This endpoint is on this Mac, so nothing leaves it and there is nothing to allow."))
            }
            let host = IntelligenceEndpoint.host(of: base)
            if IntelligenceEndpoint.hostNeedingPermission(base: base, allowedHost: endpoint.allowedHost) == nil {
                return .unavailable(reason: String(localized: "You have allowed Pharos to send to \(host)."))
            }
            return .available
        }
    }

    private func permissionCaption() -> String {
        guard let host = hostNeedingPermission() else { return "" }
        return String(localized: "Pharos sends nothing to \(host) until you allow it.")
    }

    /// Ask whether Pharos may send to `host`, saying what is sent. `then` is
    /// called with the answer.
    private func askPermission(for host: String, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Send your SQL and schema names to \(host)?")
        alert.informativeText = String(localized: """
            With the custom endpoint chosen, each feature sends \(host) the text it works from: the SQL you wrote, the names and types of the tables and columns it mentions, error messages and query plans. Describing a query also sends the definitions (DDL) of the tab's tables, which include column defaults and check constraints. SQL and plans can contain values you typed, such as a name in a WHERE clause.

            Naming a card, summarising a plan and explaining an error run on their own, so they send without asking each time. Each can be turned off in this pane.

            No feature sends the rows of a result.
            """)
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else {
            then(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            then(response == .alertFirstButtonReturn)
        }
    }

    /// The Allow button: agree to the host of the address as it stands.
    private func allowSending() {
        guard let host = hostNeedingPermission() else { return }
        askPermission(for: host) { [weak self] allowed in
            guard allowed, let self else { return }
            // The address may have changed while the sheet was up; agree
            // only to the host the sheet named.
            guard self.hostNeedingPermission() == host else { return }
            self.apply { $0.intelligence.endpoint.allowedHost = host }
        }
    }

    /// The provider popup. Choosing the custom endpoint asks first when its
    /// host has not been agreed to; Cancel leaves Apple Intelligence chosen.
    private var providerBinding: SettingsBinding<IntelligenceProvider> {
        SettingsBinding(
            get: { [stateManager] in stateManager.settings.intelligence.provider },
            set: { [weak self] provider in
                guard let self, provider != self.stateManager.settings.intelligence.provider else { return }
                guard provider == .endpoint, let host = self.hostNeedingPermission() else {
                    self.apply { $0.intelligence.provider = provider }
                    return
                }
                self.askPermission(for: host) { [weak self] allowed in
                    guard let self else { return }
                    if allowed, self.hostNeedingPermission() == host {
                        self.apply {
                            $0.intelligence.endpoint.allowedHost = host
                            $0.intelligence.provider = .endpoint
                        }
                    } else {
                        // Put the popup back on what is still chosen.
                        self.reloadFromSettings()
                    }
                }
            })
    }

    // MARK: - Test Connection

    private func testConnection() {
        checkTask?.cancel()
        let endpoint = self.endpoint
        switch IntelligenceEndpoint.baseURL(from: endpoint.baseUrl) {
        case .failure(let problem):
            lastCheck = (endpoint, problem.message)
            reloadFromSettings()
        case .success(let base):
            lastCheck = (endpoint, String(localized: "Asking the endpoint…"))
            reloadFromSettings()
            let key = PharosCore.intelligenceEndpointKey()
            checkTask = Task { @MainActor [weak self] in
                let result = await IntelligenceEndpoint.check(base: base, model: endpoint.model, key: key)
                guard let self, !Task.isCancelled else { return }
                self.lastCheck = (endpoint, result.outcome.message)
                // An endpoint that answered with a list replaces what was
                // offered; one that did not leaves nothing to offer.
                self.listedModels = (endpoint.baseUrl, result.models)
                self.reloadFromSettings()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The shortest and longest a draft may be given: 15 seconds to an hour.
    static let draftTimeoutRange = 15...3600

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
            SettingsSection(title: String(localized: "Model"), items: [
                SettingsItem(
                    id: "provider",
                    title: String(localized: "Answer with"),
                    dynamicCaption: { [weak self] in self?.providerCaption() ?? "" },
                    icon: "cpu",
                    kind: .popup(.cases(providerBinding, title: { provider in
                        switch provider {
                        case .apple: return String(localized: "Apple Intelligence")
                        case .endpoint: return String(localized: "Custom endpoint")
                        }
                    }))),
                SettingsItem(
                    id: "endpointAddress",
                    title: String(localized: "Endpoint address"),
                    dynamicCaption: { [weak self] in self?.addressCaption() ?? "" },
                    icon: "network",
                    help: String(localized: "Pharos speaks the OpenAI chat completions format, which Ollama, LM Studio, llama.cpp, vLLM and most hosted providers accept."),
                    // Under the text, at the row's width: an address is too
                    // long for the trailing slot.
                    kind: .text(.settings(\.intelligence.endpoint.baseUrl), width: 0,
                                placeholder: "https://api.example.com/v1", below: true)),
                SettingsItem(
                    id: "endpointModel",
                    title: String(localized: "Model name"),
                    dynamicCaption: { [weak self] in self?.modelCaption() ?? "" },
                    icon: "textformat.abc",
                    // The list is the endpoint's own, fetched by the same
                    // request as Test Connection. It is asked for only on a
                    // click: the request carries the API key.
                    kind: .combo(.settings(\.intelligence.endpoint.model), width: 200,
                                 options: { [weak self] in self?.modelOptions() ?? [] },
                                 reload: (title: String(localized: "List the endpoint's models"),
                                          handler: { [weak self] in self?.testConnection() }))),
                SettingsItem(
                    id: "endpointContext",
                    title: String(localized: "Context size"),
                    caption: String(localized: "The model's window. Drafting SQL fits the tables it describes into this."),
                    icon: "arrow.left.and.right.square",
                    kind: .stepper(.settings(\.intelligence.endpoint.contextTokens), range: 2048...2_000_000,
                                   unit: String(localized: "tokens"))),
                SettingsItem(
                    id: "endpointKey",
                    title: String(localized: "API key"),
                    caption: String(localized: "Kept in the Keychain, never in Pharos's settings file. Leave it empty for an endpoint that needs none."),
                    icon: "key",
                    kind: .custom { [keyModel] in
                        let hosting = NSHostingView(rootView: IntelligenceEndpointKeyEditor(model: keyModel))
                        hosting.sizingOptions = [.intrinsicContentSize]
                        return hosting
                    }),
                SettingsItem(
                    id: "endpointPermission",
                    title: String(localized: "Sending"),
                    dynamicCaption: { [weak self] in self?.permissionCaption() ?? "" },
                    icon: "paperplane",
                    help: String(localized: "Permission is for one host. Change the address to another machine and Pharos asks again before it sends anything there."),
                    kind: .action(title: String(localized: "Allow\u{2026}"), destructive: false) { [weak self] in
                        self?.allowSending()
                    },
                    availability: { [weak self] in self?.permissionAvailability() ?? .available }),
                SettingsItem(
                    id: "endpointTest",
                    title: String(localized: "Connection"),
                    dynamicCaption: { [weak self] in self?.checkCaption() ?? "" },
                    icon: "checkmark.circle",
                    kind: .action(title: String(localized: "Test Connection"), destructive: false) { [weak self] in
                        self?.testConnection()
                    }),
            ]),
            SettingsSection(title: String(localized: "Features"), items: [
                SettingsItem(
                    id: "appleIntelligence",
                    title: String(localized: "Use intelligence features"),
                    caption: String(localized: "Explain errors, suggest names and charts, draft SQL and summarise plans with the model chosen above."),
                    icon: "sparkles",
                    help: String(localized: "Apple Intelligence runs on this Mac and nothing leaves it. A custom endpoint is sent the text each feature works from; the Model section says where that goes."),
                    kind: .toggle(.settings(\.useAppleIntelligence)),
                    availability: { [weak self] in
                        // With the custom endpoint chosen the switch follows
                        // the endpoint, not what this Mac can run.
                        if let intelligence = self?.stateManager.settings.intelligence, intelligence.provider == .endpoint {
                            if let problem = ModelAvailability.endpointProblem(intelligence.endpoint) {
                                return .unavailable(reason: problem)
                            }
                            return .available
                        }
                        let availability = ModelAvailability.shared
                        if availability.systemModelIsAvailable { return .available }
                        return .unavailable(reason: availability.unavailableReason
                            ?? String(localized: "Apple Intelligence is not available on this Mac right now."))
                    }),
                SettingsItem(
                    id: "describeQuery",
                    title: String(localized: "Describe the query"),
                    caption: String(localized: "The Describe button on each query card, which drafts SQL from a sentence."),
                    icon: "text.bubble",
                    kind: .toggle(.settings(\.intelligence.describeQuery)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "draftTimeout",
                    title: String(localized: "Stop a draft after"),
                    caption: String(localized: "How long one draft may take before Pharos stops it. A slow model or a large schema needs longer."),
                    icon: "timer",
                    help: String(localized: "Counted from when the draft starts, not while it waits behind another card's draft."),
                    kind: .stepper(.settings(\.intelligence.draftTimeoutSeconds), range: Self.draftTimeoutRange,
                                   unit: String(localized: "seconds")),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "allowDraftingWriteStatements",
                    title: String(localized: "Allow drafts that write"),
                    caption: String(localized: "Off drafts reads only: a draft that is not a plain SELECT is refused instead of offered."),
                    icon: "exclamationmark.shield",
                    help: String(localized: "Pharos never runs a draft either way."),
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
                    caption: String(localized: "Fills the name field in the Save Query sheet and the card rename dialog. You can always type your own."),
                    icon: "textformat",
                    kind: .toggle(.settings(\.intelligence.suggestSavedQueryNames)),
                    dependsOn: "appleIntelligence"),
                SettingsItem(
                    id: "nameTabsAutomatically",
                    title: String(localized: "Name cards automatically"),
                    caption: String(localized: "Names a card that has no name from its SQL the first time it runs."),
                    icon: "rectangle.and.pencil.and.ellipsis",
                    help: String(localized: "A card you have named is never touched. Tabs take the name of their connection and schema."),
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
        keyModel.hasKey = PharosCore.intelligenceEndpointKey() != nil
        keyModel.store = { PharosCore.storeIntelligenceEndpointKey($0) }
        keyModel.remove = { PharosCore.deleteIntelligenceEndpointKey() }
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
