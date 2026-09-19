import AppKit

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
            SettingsSection(title: String(localized: "New Connections"), items: [
                SettingsItem(
                    id: "defaultPort",
                    title: String(localized: "Default port"),
                    caption: String(localized: "The port the Connections Manager fills in when you add a connection. It changes nothing about the connections you already have."),
                    icon: "number",
                    kind: .stepper(.settings(\.connections.defaultPort), range: 1...65535,
                                   unit: nil)),
            ]),

            SettingsSection(title: String(localized: "Session"), items: [
                SettingsItem(
                    id: "applicationName",
                    title: String(localized: "Application name"),
                    caption: String(localized: "What this app calls itself to the server — the name in pg_stat_activity, and in the server log. Leave it empty for Pharos and the version number."),
                    icon: "tag",
                    kind: .text(.settings(\.connections.applicationName), width: 200)),
                SettingsItem(
                    id: "defaultTimeZone",
                    title: String(localized: "Time zone"),
                    caption: String(localized: "The TimeZone every session asks for, which is what a timestamp with time zone is shown in. Server default leaves the server's own alone. A connection can override this in the Connections Manager."),
                    icon: "globe",
                    kind: .popup(SettingsChoice(
                        options: Self.timeZoneOptions,
                        binding: SettingsBinding<String>
                            .settings(\.connections.defaultTimeZone)
                            .map(to: { $0 }, from: { SessionTimeZone.normalized($0) })))),
                SettingsItem(
                    id: "searchPathSuffix",
                    title: String(localized: "Search path after the schema"),
                    caption: String(localized: "What follows the chosen schema in search_path, so an unqualified name can still find an object outside it. Separate several with commas. Empty means the chosen schema and nothing else."),
                    icon: "list.bullet.indent",
                    kind: .text(.settings(\.connections.searchPathSuffix), width: 200)),
                SettingsItem(
                    id: "idleInTransactionSeconds",
                    title: String(localized: "Idle transaction timeout"),
                    caption: String(localized: "How long the server lets a transaction of yours sit open and idle before it ends the session. It stops a forgotten transaction from holding locks. 0 turns it off."),
                    icon: "hourglass",
                    kind: .stepper(.settings(\.connections.idleInTransactionSeconds),
                                   range: 0...86400, unit: String(localized: "seconds"))),
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
                    caption: String(localized: "How many server connections one open database may use at once. More lets queries, metadata and exports run side by side; fewer is kinder to a server with a low connection limit."),
                    icon: "square.stack.3d.up",
                    kind: .stepper(.settings(\.connections.maxConnections), range: 1...50,
                                   unit: nil)),
                SettingsItem(
                    id: "connectTimeoutSeconds",
                    title: String(localized: "Connect timeout"),
                    caption: String(localized: "How long a connect attempt may take before it is reported as a failure. An sslmode=prefer connection spends three fifths of this trying TLS and the rest retrying without it."),
                    icon: "timer",
                    kind: .stepper(.settings(\.connections.connectTimeoutSeconds), range: 1...120,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "idleTimeoutSeconds",
                    title: String(localized: "Close idle connections after"),
                    caption: String(localized: "How long an unused connection is kept in the pool before it is closed. 0 keeps them for as long as the maximum lifetime allows."),
                    icon: "moon.zzz",
                    kind: .stepper(.settings(\.connections.idleTimeoutSeconds), range: 0...86400,
                                   unit: String(localized: "seconds"))),
                SettingsItem(
                    id: "maxLifetimeSeconds",
                    title: String(localized: "Retire connections after"),
                    caption: String(localized: "The longest a pooled connection lives before it is replaced, however busy it is. It keeps a long session from drifting away from the server's current state."),
                    icon: "arrow.triangle.2.circlepath",
                    kind: .stepper(.settings(\.connections.maxLifetimeSeconds), range: 0...86400,
                                   unit: String(localized: "seconds"))),
            ]),

            SettingsSection(title: String(localized: "Keepalive"), items: [
                SettingsItem(
                    id: "keepaliveNote",
                    title: Self.appliesLater,
                    caption: String(localized: "These ask the SERVER to probe an idle connection, which stops a firewall, a NAT or an SSH tunnel dropping it silently. 0 in all three leaves the server's own settings alone."),
                    icon: "info.circle",
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
        ]
    }
}
