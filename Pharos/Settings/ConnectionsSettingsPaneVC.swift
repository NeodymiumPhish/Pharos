import AppKit
import Combine
import SwiftUI

/// Settings ▸ Connections. What a NEW connection starts as, and how every pool
/// the app opens is tuned.
///
/// Every default is what the app did before the setting existed, so an
/// existing user sees no change until they touch a control. The Rust mirror
/// (`pharos-core/src/models/settings.rs`) names the line each default was read
/// from.
///
/// The pool and session groups carry the same caption, and it is the literal
/// truth: a pool is built at connect time and its tuning cannot be changed
/// under a live connection, so a change reaches a connection the next time it
/// opens and not before.
final class ConnectionsSettingsPaneVC: SettingsFormPaneVC {

    /// The DuckDB cloud credentials editor's model (D12).
    private let cloudModel = DuckDBCloudSecretsModel(entries: [])
    private var cloudObserver: AnyCancellable?

    init() { super.init(paneId: .connections) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The caption both the pool and the session groups carry.
    private static let appliesLater = String(
        localized: "Applies to connections opened after this change.")

    /// "Server default", then every time zone this Mac knows.
    private static var timeZoneOptions: [(title: String, value: String)] {
        [(title: String(localized: "Server default"), value: SessionTimeZone.serverDefault)]
            + SessionTimeZone.identifiers.map { (title: $0, value: $0) }
    }

    override var sections: [SettingsSection] {
        [
            // One header for the PostgreSQL rows (N4): the time zone, the
            // pool and the keepalive never reach a DuckDB database, which has
            // its own section at the end.
            SettingsSection(title: String(localized: "PostgreSQL"), items: [
                SettingsItem(
                    id: "postgresNote",
                    title: String(localized: "The settings from here to DuckDB apply to PostgreSQL connections."),
                    caption: String(localized: "DuckDB runs inside Pharos and has its own settings, at the end of this pane."),
                    icon: "server.rack",
                    kind: .display),
            ]),

            SettingsSection(title: String(localized: "New Connections"), items: [
                SettingsItem(
                    id: "defaultPort",
                    title: String(localized: "Default port"),
                    caption: String(localized: "The port the Connections Manager fills in when you add a connection."),
                    icon: "number",
                    help: String(localized: "It changes nothing about the connections you already have."),
                    kind: .stepper(.settings(\.connections.defaultPort), range: 1...65535,
                                   unit: nil)),
            ]),

            SettingsSection(title: String(localized: "Session"), items: [
                SettingsItem(
                    id: "applicationName",
                    title: String(localized: "Application name"),
                    caption: String(localized: "What this app calls itself to the server — the name in pg_stat_activity, and in the server log."),
                    icon: "tag",
                    help: String(localized: "Leave it empty for Pharos and the version number."),
                    kind: .text(.settings(\.connections.applicationName), width: 200)),
                SettingsItem(
                    id: "defaultTimeZone",
                    title: String(localized: "Time zone"),
                    caption: String(localized: "The TimeZone every session asks for, which is what a timestamp with time zone is shown in."),
                    icon: "globe",
                    help: String(localized: "Server default leaves the server's own alone. A connection can override this in the Connections Manager."),
                    kind: .popup(SettingsChoice(
                        options: Self.timeZoneOptions,
                        binding: SettingsBinding<String>
                            .settings(\.connections.defaultTimeZone)
                            .map(to: { $0 }, from: { SessionTimeZone.normalized($0) })))),
                SettingsItem(
                    id: "searchPathSuffix",
                    title: String(localized: "Search path after the schema"),
                    caption: String(localized: "What follows the chosen schema in search_path, so an unqualified name can still find an object outside it."),
                    icon: "list.bullet.indent",
                    help: String(localized: "Separate several with commas. Empty means the chosen schema and nothing else."),
                    kind: .text(.settings(\.connections.searchPathSuffix), width: 200)),
                SettingsItem(
                    id: "idleInTransactionSeconds",
                    title: String(localized: "Idle transaction timeout"),
                    caption: String(localized: "How long the server lets a transaction of yours sit open and idle before it ends the session."),
                    icon: "hourglass",
                    help: String(localized: "It stops a forgotten transaction from holding locks. 0 turns it off."),
                    kind: .stepper(.settings(\.connections.idleInTransactionSeconds),
                                   range: 0...86400, unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "tabIdleInTransactionSeconds",
                    title: String(localized: "Idle transaction timeout for query cards"),
                    caption: String(localized: "Each editor tab has its own connection, so a transaction can stay open from one card to the next. This is how long it may sit idle."),
                    icon: "hourglass.badge.plus",
                    help: String(localized: "A banner shows while a tab has a transaction open. 0 turns the timeout off; a forgotten transaction then holds its locks until you commit, roll back or close the tab."),
                    kind: .stepper(.settings(\.connections.tabIdleInTransactionSeconds),
                                   range: 0...86400, unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "maxTabSessionsPerConnection",
                    title: String(localized: "Editor tab connections per connection"),
                    caption: String(localized: "Each editor tab that runs a query holds one connection, beside the shared pool."),
                    icon: "rectangle.connected.to.line.below",
                    help: String(localized: "A small server allows few connections. Over the limit, a tab's cards run on the shared pool, without session state between cards. 0 = no limit. A DuckDB database has no limit: each tab always has its own connection."),
                    kind: .stepper(.settings(\.connections.maxTabSessionsPerConnection),
                                   range: 0...100, unit: nil)),
            ]),

            SettingsSection(title: String(localized: "Connection Pool"), items: [
                SettingsItem(
                    id: "poolNote",
                    title: Self.appliesLater,
                    caption: String(localized: "A pool is built when a connection opens, so these numbers reach a connection the next time you connect it — never a connection that is already open."),
                    icon: "info.circle",
                    kind: .display),
                SettingsItem(
                    id: "maxConnections",
                    title: String(localized: "Connections per database"),
                    caption: String(localized: "How many server connections one open database may use at once."),
                    icon: "square.stack.3d.up",
                    help: String(localized: "More lets queries, metadata and exports run side by side; fewer is kinder to a server with a low connection limit."),
                    kind: .stepper(.settings(\.connections.maxConnections), range: 1...50,
                                   unit: nil)),
                SettingsItem(
                    id: "connectTimeoutSeconds",
                    title: String(localized: "Connect timeout"),
                    caption: String(localized: "How long a connect attempt may take before it is reported as a failure."),
                    icon: "timer",
                    help: String(localized: "An sslmode=prefer connection spends three fifths of this trying TLS and the rest retrying without it."),
                    kind: .stepper(.settings(\.connections.connectTimeoutSeconds), range: 1...120,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "idleTimeoutSeconds",
                    title: String(localized: "Close idle connections after"),
                    caption: String(localized: "How long an unused connection is kept in the pool before it is closed."),
                    icon: "moon.zzz",
                    help: String(localized: "0 keeps them for as long as the maximum lifetime allows."),
                    kind: .stepper(.settings(\.connections.idleTimeoutSeconds), range: 0...86400,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "maxLifetimeSeconds",
                    title: String(localized: "Retire connections after"),
                    caption: String(localized: "The longest a pooled connection lives before it is replaced, however busy it is."),
                    icon: "arrow.triangle.2.circlepath",
                    help: String(localized: "It keeps a long session from drifting away from the server's current state."),
                    kind: .stepper(.settings(\.connections.maxLifetimeSeconds), range: 0...86400,
                                   unit: String(localized: "seconds"))),
            ]),

            SettingsSection(title: String(localized: "Keepalive"), items: [
                SettingsItem(
                    id: "keepaliveNote",
                    title: Self.appliesLater,
                    caption: String(localized: "These ask the SERVER to probe an idle connection, which stops a firewall, a NAT or an SSH tunnel dropping it silently."),
                    icon: "info.circle",
                    help: String(localized: "0 in all three leaves the server's own settings alone."),
                    kind: .display),
                SettingsItem(
                    id: "keepaliveIdleSeconds",
                    title: String(localized: "Probe after idle for"),
                    caption: String(localized: "How long a connection may be quiet before the server sends its first keepalive probe. 0 uses the server's own value."),
                    icon: "wave.3.right",
                    kind: .stepper(.settings(\.connections.keepaliveIdleSeconds), range: 0...7200,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "keepaliveIntervalSeconds",
                    title: String(localized: "Between probes"),
                    caption: String(localized: "How long the server waits between probes that go unanswered. 0 uses the server's own value."),
                    icon: "arrow.left.arrow.right",
                    kind: .stepper(.settings(\.connections.keepaliveIntervalSeconds), range: 0...600,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "keepaliveCount",
                    title: String(localized: "Probes before giving up"),
                    caption: String(localized: "How many unanswered probes end the connection. 0 uses the server's own value."),
                    icon: "exclamationmark.triangle",
                    kind: .stepper(.settings(\.connections.keepaliveCount), range: 0...20,
                                   unit: nil)),
            ]),

            // The sections above are PostgreSQL's. A DuckDB database runs in
            // this process, so it has only these.
            SettingsSection(title: String(localized: "DuckDB"), items: [
                SettingsItem(
                    id: "duckdbNote",
                    title: Self.appliesLater,
                    caption: String(localized: "A DuckDB database reads these when it opens. To change one that is open, run SET memory_limit = '4GB' or SET threads = 4 in a card. Each open database has its own limit, so several open databases can use more in all."),
                    icon: "info.circle",
                    kind: .display),
                SettingsItem(
                    id: "duckdbThreads",
                    title: String(localized: "Worker threads"),
                    caption: String(localized: "How many threads one DuckDB database may use for a query."),
                    icon: "cpu",
                    help: String(localized: "0 lets DuckDB use every core."),
                    kind: .stepper(.settings(\.connections.duckdbThreads), range: 0...256, unit: nil)),
                SettingsItem(
                    id: "duckdbMemoryLimit",
                    title: String(localized: "Memory limit"),
                    caption: String(localized: "The most memory one DuckDB database may use, such as 4GB or 512MB. Larger work spills to disk: beside a database file, or for an in-memory database into the system's temporary folder."),
                    icon: "memorychip",
                    help: String(localized: "Leave it empty for DuckDB's default, 80% of this Mac's memory."),
                    kind: .text(.settings(\.connections.duckdbMemoryLimit), width: 120)),
                SettingsItem(
                    id: "duckdbCloud",
                    title: String(localized: "Cloud storage credentials"),
                    caption: String(localized: "Keys for s3://, r2:// and gcs:// paths. Each becomes a temporary secret of every DuckDB database when it opens."),
                    icon: "key.icloud",
                    help: String(localized: "The secret keys are kept in the Keychain. A credential with no scope applies to every path of its provider."),
                    kind: .custom { [cloudModel] in
                        let hosting = NSHostingView(rootView: DuckDBCloudSecretsEditor(model: cloudModel))
                        hosting.sizingOptions = [.intrinsicContentSize]
                        return hosting
                    }),
                SettingsItem(
                    id: "duckdbExtensions",
                    title: String(localized: "Built-in extensions"),
                    caption: String(localized: "Time zones and collations (icu), INET, full-text search, SQLite files, Excel files, PostgreSQL databases, files over HTTPS and S3, JSON, Parquet and autocomplete are part of Pharos. Nothing is downloaded."),
                    icon: "puzzlepiece.extension",
                    kind: .display),
            ]),
        ]
    }

    override func loadView() {
        super.loadView()
        cloudModel.onStoreSecret = { id, secret in
            if let secret {
                if !PharosCore.storeDuckDBCloudSecret(id: id, secret: secret) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The secret key was not saved.")
                    alert.informativeText = String(localized: "The Keychain refused it. Try again, or check Keychain Access.")
                    alert.runModal()
                }
            } else {
                PharosCore.deleteDuckDBCloudSecret(id: id)
            }
        }
        cloudModel.secretExists = { PharosCore.duckDBCloudSecretExists(id: $0) }
        cloudObserver = cloudModel.$entries
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] entries in
                self?.apply { $0.connections.duckdbCloudSecrets = entries }
            }
    }

    override func reloadFromSettings() {
        super.reloadFromSettings()
        let stored = stateManager.settings.connections.duckdbCloudSecrets
        guard stored != cloudModel.entries else { return }
        populating { cloudModel.entries = stored }
    }
}
