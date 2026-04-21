# Query-Completion Notifications — Design

**Date:** 2026-04-21
**Status:** Design — pending implementation plan

## Problem

When a query takes more than a few seconds, users often switch away from Pharos to do something else. There is currently no way to know the query has finished without switching back to the app and checking. The query-running animation (2026-04-21-query-running-animation) helps when the user is looking at Pharos, but not when they are not.

## Goal

Post a macOS native notification when a query completes (success or failure), gated by user preferences so it only fires when the user is genuinely not watching. Tapping the notification brings the app forward and focuses the tab that ran the query.

## Non-Goals

- No live progress updates during execution — a single completion notification only.
- No notifications for cancellations (the user caused the cancellation; announcing it is noise).
- No cross-device / push-notification integration — local `UNUserNotificationCenter` only.
- No custom sounds, custom icons, or rich attachments — plain-text title + body.

## Design Summary

On each query completion in `ContentViewController.performQuery`, call a new `QueryNotifier` that:

1. Checks the three gates (duration ≥ threshold, and at least one of the focus conditions met).
2. Looks up authorization (requesting it lazily on the first eligible completion).
3. Posts a `UNMutableNotificationContent` through `UNUserNotificationCenter`.

The notification carries the `tabId` in `userInfo`. Tapping it (default action) activates the app and focuses the tab. A "Dismiss" action clears the notification without side effects. If the tab no longer exists, tapping just activates the app.

## Trigger Conditions

The notification fires only when ALL of the following are true:

1. **Duration gate:** `durationMs >= notifyMinDurationSeconds * 1000`. Default 5 seconds. User-configurable in settings (integer seconds, min 0, max 3600).
2. **Focus gate (OR'd):** at least one of:
   - `notifyWhenAppInactive` is `true` AND `!NSApp.isActive` at completion time.
   - `notifyWhenBackgroundTab` is `true` AND the completed tab is not the focused pane's active tab at completion time.
3. **Authorization:** the user has granted notification permission for Pharos.
4. **Not a user cancellation:** the completion is either a success or a real error (not the result of the user clicking Stop Query).

Both focus-gate preferences default to `true`.

## Content

**Success (SELECT):**
- Title: `"<ConnectionName> · Query completed"`
- Body: `"<TabName> · <N> rows in <formatted duration>"`
  - Example: `"Tab 2 · 67 rows in 1.4s"`

**Success (statement):**
- Title: `"<ConnectionName> · Query completed"`
- Body: `"<TabName> · <N> rows affected in <formatted duration>"`
  - Example: `"Tab 2 · 3 rows affected in 1.4s"`

**Error:**
- Title: `"<ConnectionName> · Query failed"`
- Body: `"<TabName> · <error message truncated to 200 chars>"`

**Formatting:**
- Duration < 1000ms: `"<ms>ms"` (unlikely to appear due to threshold, but handled).
- Duration ≥ 1000ms: `"<s.s>s"` with one decimal place (e.g., `1.4s`, `12.3s`, `301.5s`).

**If `ConnectionName` is unavailable for any reason:** use `"Pharos"` as the title prefix. Degrades gracefully.

## Architecture

### New component: `QueryNotifier`

**File:** `Pharos/Core/QueryNotifier.swift` (~120 lines).

**Public surface:**

```swift
final class QueryNotifier: NSObject {
    static let shared = QueryNotifier()

    /// Configure notification categories + actions, set the center delegate.
    /// Called once from AppDelegate.applicationDidFinishLaunching.
    func registerCategories()

    /// Post a completion notification if the gates permit.
    /// Safe to call from any completion path — all gating is internal.
    func notifyQueryCompleted(
        tabId: String,
        tabName: String,
        connectionName: String?,
        outcome: Outcome,
        durationMs: UInt64
    )

    enum Outcome {
        case select(rowCount: Int)
        case statement(rowsAffected: Int)
        case error(message: String)
    }
}

extension QueryNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler: @escaping () -> Void)
}
```

**Lazy authorization:** the first `notifyQueryCompleted` call that passes the focus + duration gates triggers `requestAuthorization(options: [.alert, .sound])`. The result is cached in `private var authorizationState: State = .unknown` (`.unknown | .requesting | .authorized | .denied`). Subsequent calls skip the request. Denial is silent — no re-prompts, no error UI.

**Notification category registered at launch:**
- Category identifier: `"QUERY_COMPLETED"`
- One action: `UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: .destructive)`
- Default action (tap the banner body) is handled via `UNNotificationDefaultActionIdentifier`.

**Notification properties on each post:**
- `categoryIdentifier = "QUERY_COMPLETED"`
- `threadIdentifier = tabId` (groups notifications for the same tab in Notification Center)
- `interruptionLevel = .active`
- `sound = .default`
- `userInfo = ["tabId": tabId]`

**Delegate routing:** `userNotificationCenter(_:didReceive:withCompletionHandler:)` inspects `response.actionIdentifier`:
- `UNNotificationDefaultActionIdentifier` → post a `.pharosActivateTab` `Notification` (via `NotificationCenter.default`) carrying the `tabId` from `userInfo`. Activate the app with `NSApp.activate(ignoringOtherApps: true)`. Downstream listener (AppDelegate) handles focus.
- `"DISMISS"` → no side effects; just complete the handler.
- Any other identifier (shouldn't happen) → no-op.

### State source

- Settings: `AppSettings.query` has three new fields (see Settings section). Read via `AppStateManager.shared.settings`.
- Tab / connection: `AppStateManager.shared.tabs`, `AppStateManager.shared.panes`, `AppStateManager.shared.connections`.
- App active state: `NSApp.isActive`.
- Focused tab: `AppStateManager.shared.panes.first { $0.id == focusedPaneId }?.activeTabId`.

`QueryNotifier` reads these on each `notifyQueryCompleted` call. No subscription / observation needed — the caller invokes it at the precise moment state matters.

### Focus handler

In `AppDelegate.applicationDidFinishLaunching`:
1. `UNUserNotificationCenter.current().delegate = QueryNotifier.shared`
2. `QueryNotifier.shared.registerCategories()`
3. Subscribe to `.pharosActivateTab` on `NotificationCenter.default`. On receipt:
   - Parse `tabId` from `userInfo`.
   - Look up the tab in `stateManager.tabs`. If absent, only activate the app (already done by the delegate). Done.
   - Set `stateManager.focusedPaneId = tab.paneId`.
   - Set `stateManager.panes[idx].activeTabId = tabId` for the owning pane (via `AppStateManager.setActiveTab(_:inPane:)` or equivalent helper — exact mutation helper confirmed during planning).
   - Activate the main window: `mainWindowController.showWindow(nil)` / `mainWindowController.window?.makeKeyAndOrderFront(nil)`.

## Component Changes

### 1. Rust — `pharos-core/src/models/settings.rs`

Add three fields to `QuerySettings`:

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
```

Update the `Default` impl to match.

### 2. Rust — `pharos-core/src/db/sqlite.rs`

Add a migration that adds the three columns (or equivalent JSON-blob handling, whichever the settings storage uses). Pattern mirrors the existing `default_schema` column migration. Update save/load paths to round-trip the new fields.

### 3. Swift mirror — `Pharos/Models/Settings.swift`

Mirror the three fields in the Swift `QuerySettings` struct with the same defaults. (Confirm field structure during planning — the file should mirror the Rust side.)

### 4. New file — `Pharos/Core/QueryNotifier.swift`

Implements the `QueryNotifier` class described above.

### 5. `Pharos/App/AppDelegate.swift`

In `applicationDidFinishLaunching`:
- Call `QueryNotifier.shared.registerCategories()` and set the notification center delegate.
- Subscribe to `.pharosActivateTab` and implement focus-change + window-activation handler.

### 6. `Pharos/ViewControllers/ContentViewController.swift` — `performQuery`

- At the top of `performQuery`, capture `let startTime = CACurrentMediaTime()` so the error path has a duration.
- On all three completion `MainActor.run` blocks (SELECT success, statement success, error), after `stateManager.updateTab(...)`, call:

```swift
QueryNotifier.shared.notifyQueryCompleted(
    tabId: tabId,
    tabName: stateManager.tabs.first { $0.id == tabId }?.name ?? "Query",
    connectionName: stateManager.connections.first { $0.id == connectionId }?.name,
    outcome: <success | statement | error>,
    durationMs: <from result.executionTimeMs or computed from startTime>
)
```

The call is non-blocking and idempotent; all gating is internal to `QueryNotifier`.

### 7. `Pharos/Sheets/SettingsSheet.swift`

Add three rows in the existing "Query" section:
- `NSSwitch`: "Notify when query completes and app is in background" → bound to `notifyWhenAppInactive`.
- `NSSwitch`: "Notify when query completes in a background tab" → bound to `notifyWhenBackgroundTab`.
- `NSTextField` numeric (min 0, max 3600): "Minimum duration for notification (seconds)" → bound to `notifyMinDurationSeconds`.

Save via the existing settings-save machinery.

## Cancellation Detection

The error path's `catch` block receives any `Error` thrown by `PharosCore.executeQuery` / `executeStatement`. User cancellations need to be distinguished so the notification is suppressed.

Pharos cancels queries via `pg_cancel_backend`, which surfaces as an error at the sqlx layer. The exact error shape is verified during planning. Candidate detection strategies (pick one during planning):
1. Match the error message against a known cancellation substring (e.g., `"query was cancelled"`, `"57014"`).
2. Check whether `tab.queryId` was marked as cancelled in a tracker before the error bubbled up (the existing cancel flow likely sets some state we can read).
3. Add a boolean flag to the call-site — `performQuery` knows it just cancelled because `stopQuery()` was invoked.

Preferred: option 2 or 3 (state-based), not substring matching. The design commits to "cancellations are silent"; the plan will commit to a specific detection mechanism.

## Accessibility

- No special handling required. macOS notifications respect the system accessibility settings (VoiceOver announces, Focus filters apply, etc.) automatically.
- Respects Do Not Disturb / Focus modes — `UNNotificationCenter` honors them without per-app logic.

## Error Handling

- **Permission denied:** silent. Log a single debug line the first time denial is detected; do not log on every subsequent call.
- **Authorization request in flight:** if a second notification arrives while `state == .requesting`, drop it (don't queue). Authorization usually completes within a second or two; buffering is not worth the complexity.
- **`UNUserNotificationCenter.add(request:)` fails:** log the error, do not surface in UI. Failures should be rare in practice.

## Testing Plan

Manual, via the running app against a test PostgreSQL database:

1. **First-run permission:** Fresh install, run `SELECT pg_sleep(6);` with app in background. System permission prompt appears. Grant → notification posts. Deny → no notification, no retry on subsequent runs.
2. **Threshold:** With `notifyMinDurationSeconds = 10`, run `SELECT pg_sleep(5);` in background → no notification. Run `SELECT pg_sleep(12);` → notification.
3. **Background tab:** Run `SELECT pg_sleep(6);` in Tab 1, switch to Tab 2 with app frontmost → notification. Set `notifyWhenBackgroundTab = false`, same scenario → no notification.
4. **App inactive:** Run `SELECT pg_sleep(6);`, Cmd+Tab away → notification on completion. Set `notifyWhenAppInactive = false`, same → no notification.
5. **Focused tab + app active:** Run `SELECT pg_sleep(6);` in focused tab, stay in app → no notification.
6. **Tap behavior:** Fire a notification → tap banner → app activates, focus jumps to the originating tab.
7. **Dismiss action:** Fire a notification → click "Dismiss" → notification clears, focus unchanged, app state unchanged.
8. **Stale tab:** Fire a notification, close the originating tab, tap the notification → app activates without tab switch; no crash.
9. **Error path:** Run `SELECT * FROM nonexistent_table;` with gates met → error notification with truncated message body.
10. **Cancel path:** Run `SELECT pg_sleep(30);`, click Stop → no notification.
11. **Sub-second query:** Run `SELECT 1;` with all gates otherwise met → no notification (duration below threshold).
12. **Multiple concurrent:** Run queries concurrently in two tabs with gates met → two notifications, grouped by tab in Notification Center via `threadIdentifier`.

## Open Questions

Resolved during planning (no design-level unknowns):
- Exact Rust/SQLite storage shape for the three new settings (JSON blob vs. columns).
- Cancellation detection mechanism (state flag vs. error-message matching).
- Swift mirror struct path for `QuerySettings`.
- AppStateManager helper for setting a pane's active tab by ID.
