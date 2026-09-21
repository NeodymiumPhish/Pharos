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
                SettingsItem(
                    id: "playSound",
                    title: String(localized: "Play a sound"),
                    caption: String(localized: "The system's default notification sound. Notification Centre can silence Pharos entirely."),
                    icon: "speaker.wave.2",
                    kind: .toggle(.settings(\.notifications.playSound))),
                SettingsItem(
                    id: "badgeDockIcon",
                    title: String(localized: "Badge the Dock icon"),
                    caption: String(localized: "Counts the queries that finished while you were in another app, whatever the gates above say."),
                    icon: "app.badge.fill",
                    help: String(localized: "Cleared when you come back."),
                    kind: .toggle(.settings(\.notifications.badgeDockIcon))),
            ]),
            SettingsSection(title: String(localized: "In the window"), items: [
                SettingsItem(
                    id: "toastDuration",
                    title: String(localized: "Message duration"),
                    caption: String(localized: "How long a message at the foot of the window stays. A few messages ask for longer on their own and keep it."),
                    icon: "bubble.left.and.text.bubble.right",
                    kind: .popup(.cases(\.notifications.toastDuration, title: { $0.displayLabel }))),
            ]),
        ]
    }
}
