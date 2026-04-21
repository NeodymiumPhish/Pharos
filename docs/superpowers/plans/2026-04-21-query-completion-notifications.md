# Query-Completion Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post macOS native notifications on query completion, gated by three user-configurable settings (app-inactive trigger, background-tab trigger, minimum duration). Tapping the notification activates the app and focuses the tab; a "Dismiss" action clears without side effects.

**Architecture:** A new `QueryNotifier` singleton wraps `UNUserNotificationCenter`. It is called from `ContentViewController.performQuery` on all three completion paths (SELECT success, statement success, error). It lazily requests notification authorization on first use, applies the user's preference gates, and posts a plain-text notification. Tap is handled via a `UNUserNotificationCenterDelegate` that posts a `.pharosActivateTab` local notification, picked up by `AppDelegate` to activate the window and call `AppStateManager.selectTab(id:)`. Cancellations are detected via a small `cancelledQueryIds: Set<String>` in `ContentViewController` that `cancelQuery()` populates and the error path checks. Settings are stored as a JSON blob in SQLite already, so adding `#[serde(default)]` fields to the Rust `QuerySettings` struct plus Swift mirror is sufficient — no DB migration needed.

**Tech Stack:** Swift/AppKit, `UserNotifications` framework (macOS 10.14+), Rust (serde for settings), Combine (existing state observation).

Design spec: [docs/superpowers/specs/2026-04-21-query-completion-notifications-design.md](../specs/2026-04-21-query-completion-notifications-design.md)

---

### Task 1: Add notification fields to Rust `QuerySettings`

**Files:**
- Modify: `pharos-core/src/models/settings.rs`

Settings are stored as a JSON blob in SQLite (`app_settings.settings_json TEXT`), so `#[serde(default)]` handles migration transparently — old JSON with missing fields deserializes with default values. No DB schema change required.

- [ ] **Step 1: Add the three fields plus default functions**

In `pharos-core/src/models/settings.rs`, update the `QuerySettings` struct (currently at lines 83-101) to:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySettings {
    pub default_limit: u32,
    pub timeout_seconds: u32,
    pub auto_commit: bool,
    pub confirm_destructive: bool,
    #[serde(default = "default_notify_when_app_inactive")]
    pub notify_when_app_inactive: bool,
    #[serde(default = "default_notify_when_background_tab")]
    pub notify_when_background_tab: bool,
    #[serde(default = "default_notify_min_duration_seconds")]
    pub notify_min_duration_seconds: u32,
}

fn default_notify_when_app_inactive() -> bool { true }
fn default_notify_when_background_tab() -> bool { true }
fn default_notify_min_duration_seconds() -> u32 { 5 }

impl Default for QuerySettings {
    fn default() -> Self {
        QuerySettings {
            default_limit: 1000,
            timeout_seconds: 30,
            auto_commit: true,
            confirm_destructive: true,
            notify_when_app_inactive: default_notify_when_app_inactive(),
            notify_when_background_tab: default_notify_when_background_tab(),
            notify_min_duration_seconds: default_notify_min_duration_seconds(),
        }
    }
}
```

Remove the old `impl Default` block that exists before your edit; your replacement above is the new one.

- [ ] **Step 2: Build Rust core and verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos/pharos-core && cargo build --release 2>&1 | tail -20`
Expected: `Finished release [optimized]` with no errors. Serde handles the optional fields via `#[serde(default)]`.

- [ ] **Step 3: Commit**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
git add pharos-core/src/models/settings.rs
git commit -m "add-notification-settings-fields-to-rust-query-settings"
```

---

### Task 2: Mirror notification fields in Swift `QuerySettings`

**Files:**
- Modify: `Pharos/Models/Settings.swift:70-75`

- [ ] **Step 1: Add the three properties**

In `Pharos/Models/Settings.swift`, update the `QuerySettings` struct:

```swift
struct QuerySettings: Codable {
    var defaultLimit: UInt32 = 1000
    var timeoutSeconds: UInt32 = 30
    var autoCommit: Bool = true
    var confirmDestructive: Bool = true
    var notifyWhenAppInactive: Bool = true
    var notifyWhenBackgroundTab: Bool = true
    var notifyMinDurationSeconds: UInt32 = 5
}
```

(Swift's synthesized `Codable` will decode old JSON without the new fields by initializing them to their default values, matching the Rust side.)

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/Settings.swift
git commit -m "mirror-notification-settings-in-swift-query-settings"
```

---

### Task 3: Add notification rows to the Settings sheet Query tab

**Files:**
- Modify: `Pharos/Sheets/SettingsSheet.swift`

- [ ] **Step 1: Declare the three controls**

In `Pharos/Sheets/SettingsSheet.swift`, find the `// Query` controls block (around lines 22-26). Replace:

```swift
    // Query
    private let defaultLimitField = NSTextField()
    private let timeoutField = NSTextField()
    private let autoCommitCheck = NSButton(checkboxWithTitle: "Auto-commit transactions", target: nil, action: nil)
    private let confirmDestructiveCheck = NSButton(checkboxWithTitle: "Confirm before DROP / DELETE / TRUNCATE", target: nil, action: nil)
```

With:

```swift
    // Query
    private let defaultLimitField = NSTextField()
    private let timeoutField = NSTextField()
    private let autoCommitCheck = NSButton(checkboxWithTitle: "Auto-commit transactions", target: nil, action: nil)
    private let confirmDestructiveCheck = NSButton(checkboxWithTitle: "Confirm before DROP / DELETE / TRUNCATE", target: nil, action: nil)
    private let notifyAppInactiveCheck = NSButton(checkboxWithTitle: "Notify when query completes and app is in background", target: nil, action: nil)
    private let notifyBackgroundTabCheck = NSButton(checkboxWithTitle: "Notify when query completes in a background tab", target: nil, action: nil)
    private let notifyMinDurationField = NSTextField()
```

- [ ] **Step 2: Add the rows to the Query tab grid**

Find `makeQueryTab()` (around line 182). Replace the `NSGridView` construction (currently 4 rows) with a 7-row version:

```swift
    private func makeQueryTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Query"

        let limitLabel = NSTextField.formLabel("Row Limit")
        defaultLimitField.formatter = numberFormatter(min: 1, max: 100_000)
        defaultLimitField.alignment = .right
        defaultLimitField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let timeoutLabel = NSTextField.formLabel("Timeout")
        timeoutField.formatter = numberFormatter(min: 1, max: 3600)
        timeoutField.alignment = .right
        timeoutField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let timeoutRow = NSStackView(views: [timeoutField, NSTextField(labelWithString: "seconds")])
        timeoutRow.orientation = .horizontal
        timeoutRow.spacing = 6

        let notifyMinDurationLabel = NSTextField.formLabel("Notification minimum")
        notifyMinDurationField.formatter = numberFormatter(min: 0, max: 3600)
        notifyMinDurationField.alignment = .right
        notifyMinDurationField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let notifyMinDurationRow = NSStackView(views: [notifyMinDurationField, NSTextField(labelWithString: "seconds")])
        notifyMinDurationRow.orientation = .horizontal
        notifyMinDurationRow.spacing = 6

        let grid = NSGridView(views: [
            [limitLabel, defaultLimitField],
            [timeoutLabel, timeoutRow],
            [NSGridCell.emptyContentView, autoCommitCheck],
            [NSGridCell.emptyContentView, confirmDestructiveCheck],
            [NSGridCell.emptyContentView, notifyAppInactiveCheck],
            [NSGridCell.emptyContentView, notifyBackgroundTabCheck],
            [notifyMinDurationLabel, notifyMinDurationRow],
        ])
        configureGrid(grid)

        let wrapper = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -16),
        ])

        item.view = wrapper
        return item
    }
```

- [ ] **Step 3: Populate the new controls from settings**

Find `populateFromSettings()` (around line 222). Locate the `// Query` block (around lines 252-256):

```swift
        // Query
        defaultLimitField.integerValue = Int(settings.query.defaultLimit)
        timeoutField.integerValue = Int(settings.query.timeoutSeconds)
        autoCommitCheck.state = settings.query.autoCommit ? .on : .off
        confirmDestructiveCheck.state = settings.query.confirmDestructive ? .on : .off
```

Replace with:

```swift
        // Query
        defaultLimitField.integerValue = Int(settings.query.defaultLimit)
        timeoutField.integerValue = Int(settings.query.timeoutSeconds)
        autoCommitCheck.state = settings.query.autoCommit ? .on : .off
        confirmDestructiveCheck.state = settings.query.confirmDestructive ? .on : .off
        notifyAppInactiveCheck.state = settings.query.notifyWhenAppInactive ? .on : .off
        notifyBackgroundTabCheck.state = settings.query.notifyWhenBackgroundTab ? .on : .off
        notifyMinDurationField.integerValue = Int(settings.query.notifyMinDurationSeconds)
```

- [ ] **Step 4: Collect the new controls back into settings**

Find the collect function (around line 290). Locate the `// Query` block:

```swift
        // Query
        s.query.defaultLimit = UInt32(clamping: defaultLimitField.integerValue)
        s.query.timeoutSeconds = UInt32(clamping: timeoutField.integerValue)
        s.query.autoCommit = autoCommitCheck.state == .on
        s.query.confirmDestructive = confirmDestructiveCheck.state == .on
```

Replace with:

```swift
        // Query
        s.query.defaultLimit = UInt32(clamping: defaultLimitField.integerValue)
        s.query.timeoutSeconds = UInt32(clamping: timeoutField.integerValue)
        s.query.autoCommit = autoCommitCheck.state == .on
        s.query.confirmDestructive = confirmDestructiveCheck.state == .on
        s.query.notifyWhenAppInactive = notifyAppInactiveCheck.state == .on
        s.query.notifyWhenBackgroundTab = notifyBackgroundTabCheck.state == .on
        s.query.notifyMinDurationSeconds = UInt32(clamping: notifyMinDurationField.integerValue)
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Smoke-test the UI (optional, user discretion)**

If you have a dev database handy, launch the app, open Settings → Query, confirm the three new rows appear, toggle them, save, reopen — confirm they persist.

- [ ] **Step 7: Commit**

```bash
git add Pharos/Sheets/SettingsSheet.swift
git commit -m "add-notification-settings-rows-to-query-tab"
```

---

### Task 4: Create `QueryNotifier`

**Files:**
- Create: `Pharos/Core/QueryNotifier.swift`

- [ ] **Step 1: Create the file**

Create `Pharos/Core/QueryNotifier.swift` with the following content:

```swift
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

    enum Outcome {
        case select(rowCount: Int)
        case statement(rowsAffected: Int)
        case error(message: String)
    }

    private enum AuthState {
        case unknown, requesting, authorized, denied
    }

    private var authState: AuthState = .unknown

    /// Register the notification category / actions and set the center delegate.
    /// Call once from `AppDelegate.applicationDidFinishLaunching`.
    func registerCategories() {
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionIdentifier,
            title: "Dismiss",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [dismiss],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    /// Post a completion notification if the configured gates permit.
    /// Safe to call from any of the three completion paths in performQuery.
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

    /// Handle tap / dismiss actions.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            guard let tabId = response.notification.request.content.userInfo["tabId"] as? String else { return }
            NotificationCenter.default.post(
                name: Self.activateTabNotification,
                object: nil,
                userInfo: ["tabId": tabId]
            )
        case Self.dismissActionIdentifier:
            // No side effects.
            return
        default:
            return
        }
    }

    /// Allow banners while the app is frontmost (users may still want to see
    /// the notification for a background-tab completion even if the app is active).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - String extension

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 2: Regenerate Xcode project and verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. XcodeGen will pick up the new file under `Pharos/Core/` automatically.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Core/QueryNotifier.swift Pharos.xcodeproj
git commit -m "add-query-notifier-for-completion-notifications"
```

---

### Task 5: Wire `AppDelegate` for launch registration and tap handling

**Files:**
- Modify: `Pharos/App/AppDelegate.swift`

- [ ] **Step 1: Register the notifier at launch and subscribe to activate-tab events**

In `Pharos/App/AppDelegate.swift`, update `applicationDidFinishLaunching` to call `QueryNotifier.shared.registerCategories()` and wire the `.pharosActivateTab` listener. Replace the current method with:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the Rust backend
        let appSupportDir = Self.appSupportDirectory()
        let success = appSupportDir.withCString { cStr in
            pharos_init(cStr)
        }
        guard success else {
            let alert = NSAlert()
            alert.messageText = "Initialization Failed"
            alert.informativeText = "Failed to initialize Pharos core. The app will now quit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Load initial state
        let state = AppStateManager.shared
        state.loadConnections()
        state.loadSettings()

        // Apply saved theme
        SettingsSheet.applyTheme(state.settings.theme)

        // Build the main menu
        NSApp.mainMenu = MainMenu.build()

        // Register query-completion notification category and delegate.
        QueryNotifier.shared.registerCategories()

        // Listen for notification taps that request tab activation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateTabNotification(_:)),
            name: QueryNotifier.activateTabNotification,
            object: nil
        )

        // Show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
    }
```

- [ ] **Step 2: Add the tab-activation handler**

Still in `AppDelegate.swift`, add this method anywhere in the class body (e.g. after `applicationShouldTerminateAfterLastWindowClosed`):

```swift
    @objc private func handleActivateTabNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        guard let tabId = notification.userInfo?["tabId"] as? String else { return }
        let state = AppStateManager.shared
        guard state.tabs.contains(where: { $0.id == tabId }) else {
            // Tab is gone (user closed it). App is already activated; graceful degrade.
            return
        }
        state.selectTab(id: tabId)
    }
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Pharos/App/AppDelegate.swift
git commit -m "wire-app-delegate-for-notification-categories-and-tap-handling"
```

---

### Task 6: Track cancellations and call `QueryNotifier` from `performQuery`

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

The `performQuery` method at lines 898-999 has three completion paths. Each needs to call `QueryNotifier.shared.notifyQueryCompleted(...)` with the right outcome and duration. The error path also needs cancellation detection: we maintain a `cancelledQueryIds: Set<String>` on the view controller, populated in `cancelQuery()` and checked in the error handler.

- [ ] **Step 1: Add the `cancelledQueryIds` property**

In `Pharos/ViewControllers/ContentViewController.swift`, near the top of the class (alongside other private state such as `hasSetInitialSplit` around line 57), add:

```swift
    /// Query IDs that the user has cancelled. Checked in the error handler to
    /// suppress the "Query failed" notification for user-initiated cancellations.
    private var cancelledQueryIds: Set<String> = []
```

- [ ] **Step 2: Populate `cancelledQueryIds` in `cancelQuery()`**

Find the `cancelQuery()` method (around line 1241):

```swift
    /// Cancel a running query in the active tab.
    func cancelQuery() {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              tab.isExecuting,
              let queryId = tab.queryId else { return }

        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
        }
    }
```

Replace with:

```swift
    /// Cancel a running query in the active tab.
    func cancelQuery() {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              tab.isExecuting,
              let queryId = tab.queryId else { return }

        // Mark this queryId as user-cancelled so the error path can suppress
        // the completion notification.
        cancelledQueryIds.insert(queryId)

        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
        }
    }
```

- [ ] **Step 3: Capture start time at top of `performQuery`**

Find the start of `performQuery` (around line 898). After the initial `guard` block but before `stateManager.updateTab(id: tabId) { ...` at line 917, add `let startTime = CACurrentMediaTime()`. Specifically, locate:

```swift
        let queryId = UUID().uuidString
        let color = createResultTab ? ResultTab.nextColor() : .clear

        stateManager.updateTab(id: tabId) { tab in
```

Replace with:

```swift
        let queryId = UUID().uuidString
        let color = createResultTab ? ResultTab.nextColor() : .clear
        let startTime = CACurrentMediaTime()

        stateManager.updateTab(id: tabId) { tab in
```

- [ ] **Step 4: Call the notifier on SELECT success (site 1)**

Find the SELECT-success `MainActor.run` block (around lines 939-958). It currently reads:

```swift
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.runningSegmentIndex = nil
                            tab.result = result
                        }
                        if createResultTab {
                            var rt = ResultTab(
                                id: UUID().uuidString, segmentIndex: segmentIndex,
                                sql: sql, lineRange: lineRange, color: color, timestamp: Date()
                            )
                            rt.customLabel = customLabel
                            rt.queryResult = result
                            rt.executionTimeMs = result.executionTimeMs
                            self.addResultTab(rt)
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                    }
```

After `NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)` and before the closing `}` of the `await MainActor.run { ... }` block, add:

```swift
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .select(rowCount: result.rowCount),
                            durationMs: result.executionTimeMs
                        )
```

(Note: `result.executionTimeMs` is already `UInt64`, no cast needed.)

So the block ends:

```swift
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .select(rowCount: result.rowCount),
                            durationMs: result.executionTimeMs
                        )
                    }
```

- [ ] **Step 5: Call the notifier on statement success (site 2)**

Find the statement-success `MainActor.run` block (around lines 963-982). At the end of that block, just before the closing `}`, add a parallel call. The block currently ends:

```swift
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showExecuteResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                    }
```

Locate the `NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)` inside the statement-success block (distinct from the SELECT-success one — both exist). Add immediately after it:

```swift
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .statement(rowsAffected: Int(result.rowsAffected)),
                            durationMs: result.executionTimeMs
                        )
```

- [ ] **Step 6: Call the notifier on error (site 3), skipping user cancellations**

Find the error `catch` block (around lines 984-997):

```swift
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    self.stateManager.updateTab(id: tabId) { tab in
                        tab.isExecuting = false
                        tab.queryId = nil
                        tab.runningSegmentIndex = nil
                        tab.error = message
                    }
                    if self.stateManager.activeTabId == tabId {
                        self.resultsVC.showError(message)
                        self.markEditorError(message: message, sql: sql)
                    }
                }
            }
```

Replace with:

```swift
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    self.stateManager.updateTab(id: tabId) { tab in
                        tab.isExecuting = false
                        tab.queryId = nil
                        tab.runningSegmentIndex = nil
                        tab.error = message
                    }
                    if self.stateManager.activeTabId == tabId {
                        self.resultsVC.showError(message)
                        self.markEditorError(message: message, sql: sql)
                    }

                    // Suppress notification for user-initiated cancellations.
                    let wasCancelled = self.cancelledQueryIds.remove(queryId) != nil
                    if !wasCancelled {
                        let elapsedMs = UInt64((CACurrentMediaTime() - startTime) * 1000)
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .error(message: message),
                            durationMs: elapsedMs
                        )
                    }
                }
            }
```

- [ ] **Step 7: Add the `fireCompletionNotification` helper**

Add this private helper anywhere in `ContentViewController` (e.g. just after `performQuery` ends around line 999):

```swift
    /// Assemble metadata and invoke QueryNotifier. Single entry point from the
    /// three completion paths so the argument-assembly logic lives in one place.
    private func fireCompletionNotification(
        tabId: String,
        connectionId: String,
        outcome: QueryNotifier.Outcome,
        durationMs: UInt64
    ) {
        let tabName = stateManager.tabs.first { $0.id == tabId }?.name ?? "Query"
        let connectionName = stateManager.connections.first { $0.id == connectionId }?.name
        QueryNotifier.shared.notifyQueryCompleted(
            tabId: tabId,
            tabName: tabName,
            connectionName: connectionName,
            outcome: outcome,
            durationMs: durationMs
        )
    }
```

- [ ] **Step 8: Clean up stale cancelledQueryIds on success paths**

At each of the two success paths (SELECT success and statement success), also remove the queryId from `cancelledQueryIds` to prevent unbounded growth if a cancellation race results in a successful completion. Find both completion `MainActor.run` blocks (the ones modified in Steps 4 and 5). In each, immediately after the `self.stateManager.updateTab(id: tabId) { ... }` call, add:

```swift
                        self.cancelledQueryIds.remove(queryId)
```

So Site 1's block starts:

```swift
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.runningSegmentIndex = nil
                            tab.result = result
                        }
                        self.cancelledQueryIds.remove(queryId)
```

(The error-path `remove` is already handled in Step 6's `cancelledQueryIds.remove(queryId) != nil` check.)

- [ ] **Step 9: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 10: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "wire-query-notifier-into-performQuery-completion-paths"
```

---

### Task 7: Manual verification

**Files:** None (manual testing only).

- [ ] **Step 1: Launch the app**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build
open Pharos.xcodeproj   # then Cmd+R
```

Connect to a PostgreSQL database.

- [ ] **Step 2: First-run permission prompt**

In a fresh install (or after resetting notification permission for Pharos in System Settings), run a query that will pass the gates:

```sql
SELECT pg_sleep(6);
```

Cmd+Tab away before it completes. When it finishes, macOS should prompt for notification permission the first time. Grant it. Run the same query again (still Cmd+Tab away) — a notification should appear with title `<ConnectionName> · Query completed` and body `<TabName> · 1 rows in 6.0s`.

Expected: PASS if the permission prompt appears on first use and the notification posts on second use.

- [ ] **Step 3: Duration threshold**

In Settings → Query, set "Notification minimum" to `10` seconds. Save.

Run `SELECT pg_sleep(5);` with app in background. Expected: no notification.
Run `SELECT pg_sleep(12);` with app in background. Expected: notification posts.

Reset the threshold to `5` when done.

- [ ] **Step 4: Background-tab trigger**

Ensure both gate checkboxes are ON. Open a second query tab (Cmd+T). In Tab 1, run `SELECT pg_sleep(6);`. While it runs, switch to Tab 2 (stay in the app). Expected: notification posts when Tab 1's query completes, because Tab 1 is not the focused tab even though the app is active.

Disable "Notify when query completes in a background tab". Repeat the scenario. Expected: no notification (app is active + focused-tab gate off = both gates fail).

- [ ] **Step 5: App-inactive trigger**

Re-enable "Notify when query completes in a background tab". Disable "Notify when query completes and app is in background".

Run `SELECT pg_sleep(6);` in the focused tab, Cmd+Tab away. Expected: no notification (only the app-inactive gate would apply, and it's off).

Run `SELECT pg_sleep(6);` in Tab 1, switch to Tab 2 (stay in app). Expected: notification posts (the background-tab gate is on).

- [ ] **Step 6: All gates satisfied, focused + active**

With both gate checkboxes ON, run `SELECT pg_sleep(6);` in the focused tab of the focused pane, stay in the app. Expected: no notification (neither gate triggers).

- [ ] **Step 7: Tap behavior**

Run `SELECT pg_sleep(6);`, Cmd+Tab away. When the notification appears, click the notification body (not Dismiss). Expected: Pharos activates, the originating tab becomes focused (if you switched tabs while away, it should switch back to the query tab).

- [ ] **Step 8: Dismiss action**

Run `SELECT pg_sleep(6);`, Cmd+Tab away. Hover the notification and click "Dismiss" (may require expanding the banner). Expected: notification clears, Pharos does not activate, focused tab is unchanged.

- [ ] **Step 9: Stale-tab tap**

Run `SELECT pg_sleep(8);`, Cmd+Tab away, and while the query is still running close the originating tab back in Pharos (you'll need to switch back briefly — or run two queries, close one tab). When the notification for the closed tab appears, tap it. Expected: Pharos activates; no crash; no tab switch.

- [ ] **Step 10: Error path**

Run `SELECT * FROM nonexistent_table;` with app in background. Expected: error notification with title `<ConnectionName> · Query failed` and body containing the truncated Postgres error message.

- [ ] **Step 11: Cancel path**

Run `SELECT pg_sleep(30);`, Cmd+Tab away, then Cmd+Tab back and click Stop Query. Expected: NO notification (the cancellation should be silent).

- [ ] **Step 12: Sub-threshold duration**

With threshold `5`, run `SELECT 1;` in a background tab (gates otherwise satisfied). Expected: no notification (duration below threshold).

- [ ] **Step 13: Permission denial**

Reset notification permission for Pharos in System Settings → Notifications. Relaunch the app. Run `SELECT pg_sleep(6);` in background. When the permission prompt appears, click "Don't Allow". Run another qualifying query. Expected: no notification, no second prompt, app stays responsive.

- [ ] **Step 14: Final commit of verification tweaks (if any)**

If any step surfaced a bug, fix it and commit with a descriptive message. If everything passes, no final commit needed.

---

## Summary

**New files:** `Pharos/Core/QueryNotifier.swift` (~180 lines).
**Modified files:** `pharos-core/src/models/settings.rs`, `Pharos/Models/Settings.swift`, `Pharos/Sheets/SettingsSheet.swift`, `Pharos/App/AppDelegate.swift`, `Pharos/ViewControllers/ContentViewController.swift`.
**Commits:** 7 atomic commits (one per implementation task, plus any verification fixes).
**Dependencies added:** None (`UserNotifications` is part of macOS).
**DB migrations:** None (settings are stored as a JSON blob; `#[serde(default)]` handles field addition).
