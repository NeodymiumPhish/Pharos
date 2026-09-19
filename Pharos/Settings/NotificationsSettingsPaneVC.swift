import AppKit

/// Settings ▸ Notifications. When a finished query tells you.
final class NotificationsSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .notifications) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static let minimumDurationRange = 0...3600

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Query completion"), items: [
                SettingsItem(
                    id: "notifyAppInactive",
                    title: String(localized: "Notify when the app is in the background"),
                    icon: "app.badge",
                    kind: .toggle(.settings(\.query.notifyWhenAppInactive))),
                SettingsItem(
                    id: "notifyBackgroundTab",
                    title: String(localized: "Notify for a background tab"),
                    caption: String(localized: "A query that finishes in a tab you are not viewing."),
                    icon: "rectangle.stack.badge.plus",
                    kind: .toggle(.settings(\.query.notifyWhenBackgroundTab))),
                SettingsItem(
                    id: "notifyMinDuration",
                    title: String(localized: "Minimum duration"),
                    caption: String(localized: "Queries shorter than this do not notify."),
                    icon: "hourglass",
                    kind: .stepper(.settings(\.query.notifyMinDurationSeconds), range: Self.minimumDurationRange, unit: String(localized: "seconds"))),
            ]),
        ]
    }
}
