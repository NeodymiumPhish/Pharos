import AppKit

/// Settings ▸ Security & Privacy. What Pharos does with your data on this Mac.
///
/// Both switches take effect while the window is open: `SettingsEffects`
/// follows the stored values and starts or stops the service behind each one.
/// Neither sends anything anywhere, which is what the section caption says in
/// as few words as it can be said.
final class SecuritySettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .security) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var mcpObserver: NSObjectProtocol?
    private lazy var mcpAppsView = MCPAppsListView()

    override func reloadFromSettings() {
        super.reloadFromSettings()
        mcpAppsView.reload()
    }

    override func loadView() {
        super.loadView()
        // Who is connected changes without a settings change.
        mcpObserver = NotificationCenter.default.addObserver(
            forName: MCPServerController.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromSettings() }
        }
    }

    deinit {
        if let mcpObserver { NotificationCenter.default.removeObserver(mcpObserver) }
    }

    /// Put the `mcpServers` entry for Claude desktop and LM Studio on the
    /// pasteboard.
    private func copyMCPConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPServerController.clientConfigJSON, forType: .string)
        Toast.show(in: view, message: String(localized: "Configuration copied. Paste it into your AI app's MCP settings."),
                   style: .success)
    }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Privacy"), items: [
                SettingsItem(
                    id: "privacyNote",
                    title: String(localized: "Nothing leaves this Mac."),
                    caption: String(localized: "Pharos has no account, no telemetry and no analytics."),
                    icon: "lock.shield",
                    help: String(localized: "Everything below is written to your own disk and read by your own Mac."),
                    kind: .display),
            ]),
            SettingsSection(title: String(localized: "AI Apps (MCP)"), items: [
                SettingsItem(
                    id: "mcpServerEnabled",
                    title: String(localized: "Allow AI apps to use Pharos"),
                    dynamicCaption: { MCPServerController.shared.statusText },
                    icon: "sparkles",
                    help: String(localized: "AI apps on this Mac that speak the Model Context Protocol (Claude, LM Studio and others) can list your connections and Sessions, add query cards to your tabs, run them and read their results. Everything they do appears in the Pharos window. They connect through a file only your user account can open; nothing listens on the network."),
                    kind: .toggle(.settings(\.security.mcpServerEnabled))),
                SettingsItem(
                    id: "mcpApps",
                    title: String(localized: "AI apps"),
                    caption: String(localized: "Each app that has used Pharos, told apart by its code signature. Choose Local for an app whose model runs on this Mac, such as LM Studio, and Cloud for one whose model runs elsewhere, such as Claude."),
                    icon: "app.badge.checkmark",
                    kind: .custom { [unowned self] in self.mcpAppsView },
                    dependsOn: "mcpServerEnabled"),
                SettingsItem(
                    id: "mcpWrites",
                    title: String(localized: "AI apps that can change data"),
                    caption: String(localized: "INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE and GRANT. Other apps are refused; these still confirm each run in Pharos."),
                    icon: "exclamationmark.shield",
                    kind: .popup(.cases(\.security.mcpWrites, title: { $0.displayLabel })),
                    dependsOn: "mcpServerEnabled"),
                SettingsItem(
                    id: "mcpUnconfirmedWrites",
                    title: String(localized: "AI apps that can change data without asking"),
                    caption: String(localized: "These apps' INSERT, UPDATE, DELETE and other changes run without the confirmation sheet. Only apps that can change data are affected."),
                    icon: "exclamationmark.triangle",
                    kind: .popup(.cases(\.security.mcpUnconfirmedWrites, title: { $0.displayLabel })),
                    dependsOn: "mcpServerEnabled"),
                SettingsItem(
                    id: "mcpVariableValues",
                    title: String(localized: "AI apps that can read variable values"),
                    caption: String(localized: "Of the variables you share with AI apps (Variable Manager ▸ AI apps). Other apps see a shared variable's name and type, not its value. Values are filled in when a card runs either way."),
                    icon: "curlybraces",
                    kind: .popup(.cases(\.security.mcpVariableValues, title: { $0.displayLabel })),
                    dependsOn: "mcpServerEnabled"),
                SettingsItem(
                    id: "mcpUnconfirmedVariableChanges",
                    title: String(localized: "AI apps that can change variables without asking"),
                    caption: String(localized: "These apps create, change and delete query variables without the confirmation sheet. Pharos says in its window what they changed."),
                    icon: "curlybraces.square",
                    kind: .popup(.cases(\.security.mcpUnconfirmedVariableChanges, title: { $0.displayLabel })),
                    dependsOn: "mcpServerEnabled"),
                SettingsItem(
                    id: "mcpConfiguration",
                    title: String(localized: "Configuration for your AI app"),
                    caption: String(localized: "The mcpServers entry that adds Pharos to Claude desktop or LM Studio."),
                    icon: "doc.on.clipboard",
                    kind: .action(title: String(localized: "Copy"), destructive: false) { [weak self] in
                        self?.copyMCPConfiguration()
                    }),
            ]),
            SettingsSection(title: String(localized: "Spotlight"), items: [
                SettingsItem(
                    id: "indexSavedQueriesInSpotlight",
                    title: String(localized: "Find saved queries in Spotlight"),
                    caption: String(localized: "Puts each saved query's name, folder and SQL in the system index, so Spotlight opens it."),
                    icon: "magnifyingglass",
                    help: String(localized: "Turning this off removes them again."),
                    kind: .toggle(.settings(\.security.indexSavedQueriesInSpotlight))),
            ]),
            SettingsSection(title: String(localized: "Passwords"), items: [
                SettingsItem(
                    id: "clearPasswordCacheOnSleep",
                    title: String(localized: "Forget typed passwords when this Mac sleeps"),
                    caption: String(localized: "A password you type into a connection that does not remember it is held until Pharos quits."),
                    icon: "moon.zzz",
                    help: String(localized: "This drops it when the Mac goes to sleep instead, so you are asked again on waking. Passwords kept in your keychain are not affected."),
                    kind: .toggle(.settings(\.security.clearPasswordCacheOnSleep))),
            ]),
            SettingsSection(title: String(localized: "Diagnostics"), items: [
                SettingsItem(
                    id: "collectPerformanceMetrics",
                    title: String(localized: "Collect performance reports"),
                    caption: String(localized: "Writes the system's daily hang and performance payloads to ~/Library/Logs/Pharos, for you to read or attach to a bug report."),
                    icon: "waveform.path.ecg",
                    help: String(localized: "Nothing is uploaded."),
                    kind: .toggle(.settings(\.security.collectPerformanceMetrics))),
            ]),
        ]
    }
}
