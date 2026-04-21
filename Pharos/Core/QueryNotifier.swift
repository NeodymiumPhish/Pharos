import AppKit
import UserNotifications

/// Shared service that posts macOS native notifications on query completion,
/// gated by user preferences. Tap activates the app and focuses the originating
/// tab via a `.pharosActivateTab` local notification handled in AppDelegate.
///
/// The first call that passes the user-preference gates triggers lazy
/// authorization. Denial is silent — no re-prompts, no error UI.
final class QueryNotifier: NSObject {

    static let shared = QueryNotifier()

    /// Notification category identifier registered at launch.
    static let categoryIdentifier = "QUERY_COMPLETED"
    /// Identifier for the inline "Dismiss" action.
    static let dismissActionIdentifier = "DISMISS"
    /// Posted when the user taps the notification body (default action).
    /// `userInfo["tabId"]` carries the String tab identifier.
    static let activateTabNotification = Notification.Name("pharosActivateTab")

    /// Notification category for update-available notifications.
    static let updateCategoryIdentifier = "UPDATE_AVAILABLE"
    /// Identifier for the "Copy brew command" action on update notifications.
    static let copyBrewCommandActionIdentifier = "COPY_BREW_COMMAND"
    /// Command copied to the clipboard on the "Copy brew command" action.
    static let brewUpgradeCommand = "brew upgrade pharos"

    enum Outcome {
        case select(rowCount: Int)
        case statement(rowsAffected: Int)
        case error(message: String)
    }

    private enum AuthState {
        case unknown, requesting, authorized, denied
    }

    private var authState: AuthState = .unknown

    /// Register the notification categories / actions and set the center delegate.
    /// Call once from `AppDelegate.applicationDidFinishLaunching`.
    func registerCategories() {
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionIdentifier,
            title: "Dismiss",
            options: [.destructive]
        )
        let queryCategory = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [dismiss],
            intentIdentifiers: [],
            options: []
        )

        let copyBrew = UNNotificationAction(
            identifier: Self.copyBrewCommandActionIdentifier,
            title: "Copy brew command",
            options: []
        )
        let updateCategory = UNNotificationCategory(
            identifier: Self.updateCategoryIdentifier,
            actions: [copyBrew],
            intentIdentifiers: [],
            options: []
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([queryCategory, updateCategory])
        center.delegate = self
    }

    /// Post a completion notification if the configured gates permit.
    /// Safe to call from any of the three completion paths in performQuery.
    @MainActor
    func notifyQueryCompleted(
        tabId: String,
        tabName: String,
        connectionName: String?,
        outcome: Outcome,
        durationMs: UInt64
    ) {
        let settings = AppStateManager.shared.settings.query

        // Gate 1: duration threshold.
        let minMs = UInt64(settings.notifyMinDurationSeconds) * 1000
        guard durationMs >= minMs else { return }

        // Gate 2: focus conditions (OR).
        let appInactive = !NSApp.isActive
        let focusedPaneId = AppStateManager.shared.focusedPaneId
        let focusedPane = AppStateManager.shared.panes.first { $0.id == focusedPaneId }
        let isBackgroundTab = focusedPane?.activeTabId != tabId

        let appInactiveAllows = settings.notifyWhenAppInactive && appInactive
        let backgroundTabAllows = settings.notifyWhenBackgroundTab && isBackgroundTab

        guard appInactiveAllows || backgroundTabAllows else { return }

        // Gate 3: authorization (lazy).
        requestAuthorizationIfNeeded { [weak self] authorized in
            guard authorized else { return }
            self?.postNotification(
                tabId: tabId, tabName: tabName,
                connectionName: connectionName, outcome: outcome,
                durationMs: durationMs
            )
        }
    }

    /// Post an update-available notification. Applies the same authorization gate
    /// as `notifyQueryCompleted` but no other gates (the caller is responsible for
    /// rate-limiting and per-version dedupe).
    /// Not `@MainActor` — does not touch main-actor-isolated state, so callers
    /// from URLSession completions or background tasks don't need to hop.
    func postUpdateAvailableNotification(newVersion: String, currentVersion: String, releasesUrl: String) {
        requestAuthorizationIfNeeded { [weak self] authorized in
            guard authorized else { return }
            self?.postUpdate(newVersion: newVersion, currentVersion: currentVersion, releasesUrl: releasesUrl)
        }
    }

    private func postUpdate(newVersion: String, currentVersion: String, releasesUrl: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pharos · Update available"
        content.body = "Version \(newVersion) is available. Current: \(currentVersion)."
        content.sound = .default
        content.categoryIdentifier = Self.updateCategoryIdentifier
        content.threadIdentifier = "pharos-update"
        content.interruptionLevel = .active
        content.userInfo = ["releasesUrl": releasesUrl]

        let request = UNNotificationRequest(
            identifier: "pharos-update-\(newVersion)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Authorization

    private func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        switch authState {
        case .authorized:
            completion(true)
        case .denied, .requesting:
            completion(false)
        case .unknown:
            authState = .requesting
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.authState = granted ? .authorized : .denied
                    completion(granted)
                }
            }
        }
    }

    // MARK: - Posting

    private func postNotification(
        tabId: String,
        tabName: String,
        connectionName: String?,
        outcome: Outcome,
        durationMs: UInt64
    ) {
        let content = UNMutableNotificationContent()
        content.title = Self.titleText(connectionName: connectionName, outcome: outcome)
        content.body = Self.bodyText(tabName: tabName, outcome: outcome, durationMs: durationMs)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = tabId
        content.interruptionLevel = .active
        content.userInfo = ["tabId": tabId]

        let request = UNNotificationRequest(
            identifier: "query-completed-\(tabId)-\(UUID().uuidString)",
            content: content,
            trigger: nil  // immediate delivery
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Text Formatting

    private static func titleText(connectionName: String?, outcome: Outcome) -> String {
        let prefix = connectionName?.nonEmpty ?? "Pharos"
        switch outcome {
        case .select, .statement:
            return "\(prefix) · Query completed"
        case .error:
            return "\(prefix) · Query failed"
        }
    }

    private static func bodyText(tabName: String, outcome: Outcome, durationMs: UInt64) -> String {
        switch outcome {
        case .select(let rowCount):
            return "\(tabName) · \(rowCount) rows in \(formatDuration(durationMs))"
        case .statement(let rowsAffected):
            return "\(tabName) · \(rowsAffected) rows affected in \(formatDuration(durationMs))"
        case .error(let message):
            let truncated = message.count > 200 ? String(message.prefix(200)) + "…" : message
            return "\(tabName) · \(truncated)"
        }
    }

    private static func formatDuration(_ ms: UInt64) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.1fs", seconds)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension QueryNotifier: UNUserNotificationCenterDelegate {

    /// Handle tap / action-button responses for both QUERY_COMPLETED and UPDATE_AVAILABLE.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let category = response.notification.request.content.categoryIdentifier
        let userInfo = response.notification.request.content.userInfo

        switch category {
        case Self.categoryIdentifier:
            // QUERY_COMPLETED
            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                guard let tabId = userInfo["tabId"] as? String else { return }
                NotificationCenter.default.post(
                    name: Self.activateTabNotification,
                    object: nil,
                    userInfo: ["tabId": tabId]
                )
            case Self.dismissActionIdentifier:
                return
            default:
                return
            }
        case Self.updateCategoryIdentifier:
            // UPDATE_AVAILABLE
            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                guard let urlString = userInfo["releasesUrl"] as? String,
                      let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)
            case Self.copyBrewCommandActionIdentifier:
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(Self.brewUpgradeCommand, forType: .string)
            default:
                return
            }
        default:
            return
        }
    }

    /// Allow banners while the app is frontmost (users may still want to see
    /// the notification for a background-tab completion even if the app is active).
    /// Including `.list` ensures the notification also persists in Notification Center.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

// MARK: - String extension

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
