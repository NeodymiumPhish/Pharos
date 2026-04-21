# Update-Available Notifications — Design

**Date:** 2026-04-21
**Status:** Design — pending implementation plan

## Problem

Pharos has no mechanism to tell users when a newer version is available. Users installing via Homebrew have to run `brew upgrade pharos` on their own cadence to discover updates. For casual users, updates may be missed entirely.

## Goal

Detect when a newer stable release is published to the GitHub repository and post a macOS native notification so the user knows to upgrade. Tapping the notification opens the release page; a secondary action copies the `brew upgrade pharos` command to the clipboard. A single Settings toggle gives users opt-out control.

## Non-Goals

- No in-app downloader or installer. Updates are performed via Homebrew (or whatever the user's install method is) — this feature is informational only.
- No pre-release / beta notifications. `/releases/latest` already excludes pre-releases; a future opt-in setting could lift this if demand emerges.
- No changelog rendering in the notification body. Users click through to GitHub for release notes.
- No authenticated GitHub access. Unauthenticated calls are sufficient (~1 per day per user, well under the 60/hr/IP limit).

## Design Summary

A new `UpdateChecker` singleton runs at app launch (and every 6 hours thereafter) to poll `https://api.github.com/repos/NeodymiumPhish/Pharos/releases/latest`. When the returned `tag_name` parses to a version greater than the current `CFBundleShortVersionString`, it posts a notification via the existing `QueryNotifier` infrastructure under a new `UPDATE_AVAILABLE` category.

**Notification content:**
- Title: `"Pharos · Update available"`
- Body: `"Version <new> is available. Current: <current>."`

**Actions:**
- Default tap → open the release page URL (`html_url` from the GitHub response) via `NSWorkspace.shared.open(_:)`.
- `COPY_BREW_COMMAND` action → copy `"brew upgrade pharos"` to `NSPasteboard.general`.

**Suppression / rate-limits:**
- HTTP request made at most once per 24 hours (timestamp in `UserDefaults`).
- Per-version dedupe: once we've notified about version X, we don't notify again for X. Only newer versions trigger.
- Network failures, non-2xx responses, unparseable JSON, and unparseable tag strings are silent — debug-logged only.
- If the `checkForUpdates` setting is off, no HTTP call is made.

## Architecture

### New component: `UpdateChecker`

**File:** `Pharos/Core/UpdateChecker.swift` (~150 lines).

**Public surface:**

```swift
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Start the periodic check. Call once from AppDelegate.applicationDidFinishLaunching.
    /// Fires an immediate check (rate-limit-aware) and schedules a 6-hour repeating timer.
    func start()

    /// Run one check now, respecting the 24h HTTP cache and per-version dedupe.
    /// Safe to call repeatedly. No-ops if `settings.checkForUpdates` is false.
    func checkNow() async
}
```

**Internal state (UserDefaults):**

- Key `"updateCheckerLastCheckedAt"` (Date) — timestamp of the most recent *successful* HTTP call. Failures do NOT update this, so retries happen on the next tick.
- Key `"updateCheckerLastNotifiedVersion"` (String) — the `tag_name` we most recently posted a notification about. Used for per-version dedupe.

**Timer:** `Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true)` on the main run loop. Each tick invokes `Task { await self.checkNow() }`. Always-running — the user-preference gate is inside `checkNow()` so toggling the setting at runtime takes effect on the next tick.

### HTTP flow

- `URLSession.shared` with a `URLRequest` to `https://api.github.com/repos/NeodymiumPhish/Pharos/releases/latest`.
- Headers:
  - `User-Agent: "Pharos/<currentVersion>"` (GitHub requires a UA for unauthenticated API calls; they 403 otherwise).
  - `Accept: application/vnd.github+json`.
- Timeout: 10 seconds.
- Codable struct for response (subset of fields):
  ```swift
  private struct GitHubRelease: Decodable {
      let tag_name: String
      let html_url: String
  }
  ```
- Error handling: any failure (network, non-2xx, decode failure, unparseable version) → debug log via `NSLog`, return silently, do NOT update `lastCheckedAt`.

### Version comparison

- Parse tag: strip leading `v` (case-insensitive), split on `.`, take the first three segments, parse each as `Int`. Return `nil` if parsing fails for any segment.
- Compare two `[Int]` arrays lexicographically. If either side is `nil`, treat as "not newer" (no notification).
- Example: `"v0.2.0"` → `[0, 2, 0]`. `"0.1.3"` → `[0, 1, 3]`. Comparison: `[0, 2, 0] > [0, 1, 3]` → update.
- Pre-release tags like `"v0.2.0-beta.1"` are unlikely to appear because `/releases/latest` excludes them, but if one does leak through, the `-beta.1` suffix will cause the third segment parse to fail and the comparison returns "not newer."

### Current version

Read from the main bundle:

```swift
let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
```

This matches `Info.plist`'s `CFBundleShortVersionString` (currently `"0.1.0"`).

### Notification posting

`UpdateChecker` does not own `UNUserNotificationCenter` directly. It calls a new public method on `QueryNotifier` so all notification plumbing stays in one place:

```swift
extension QueryNotifier {
    /// Post an update-available notification. No gates beyond authorization.
    @MainActor
    func postUpdateAvailableNotification(newVersion: String, currentVersion: String, releasesUrl: String)
}
```

Internally:
- Content: category `UPDATE_AVAILABLE`, title `"Pharos · Update available"`, body `"Version <new> is available. Current: <current>."`, `sound = .default`, `threadIdentifier = "pharos-update"`, `interruptionLevel = .active`.
- `userInfo = ["releasesUrl": releasesUrl]`.
- Request identifier `"pharos-update-\(newVersion)"` so the system replaces stale notifications for the same version rather than stacking them.

### Notification categories (extended in `QueryNotifier.registerCategories`)

Currently registers one category (`QUERY_COMPLETED`). We extend to register two:

- `QUERY_COMPLETED` (existing): `DISMISS` action (destructive).
- `UPDATE_AVAILABLE` (new): `COPY_BREW_COMMAND` action (default style, title `"Copy brew command"`).

`UNUserNotificationCenter.setNotificationCategories([query, update])` — call is idempotent and replaces the full set.

### Delegate routing (extended in `QueryNotifier.didReceive`)

Today's `didReceive` dispatches on `response.actionIdentifier`. With two categories, we first dispatch on `response.notification.request.content.categoryIdentifier`, then on `actionIdentifier`:

- `QUERY_COMPLETED`:
  - `UNNotificationDefaultActionIdentifier` → existing: post `.pharosActivateTab` with `tabId`.
  - `DISMISS` → no-op.
- `UPDATE_AVAILABLE`:
  - `UNNotificationDefaultActionIdentifier` → open `userInfo["releasesUrl"]` via `NSWorkspace.shared.open(_:)` if present.
  - `COPY_BREW_COMMAND` → clear `NSPasteboard.general` and write `"brew upgrade pharos"` as a string.
- Default (unknown category/action) → no-op.

`willPresent` stays unchanged — still returns `[.banner, .list, .sound]` for both categories.

### Settings

**Rust — `pharos-core/src/models/settings.rs`:** add a top-level field to `AppSettings`:

```rust
#[serde(default = "default_check_for_updates")]
pub check_for_updates: bool,
```

with `fn default_check_for_updates() -> bool { true }` and the `Default` impl updated. Same `app_settings.settings_json` JSON-blob storage — no DB migration.

**Swift mirror — `Pharos/Models/Settings.swift`:** add to `AppSettings`:

```swift
var checkForUpdates: Bool = true
```

**Settings sheet — `Pharos/Sheets/SettingsSheet.swift`:** add one checkbox to the **General** tab:

- Declare `private let checkForUpdatesCheck = NSButton(checkboxWithTitle: "Check for updates in the background", target: nil, action: nil)`.
- Add a row to the General tab's grid.
- Read in `populateFromSettings()`: `checkForUpdatesCheck.state = settings.checkForUpdates ? .on : .off`.
- Write in `collectSettings()`: `s.checkForUpdates = checkForUpdatesCheck.state == .on`.

### App launch wiring

In `AppDelegate.applicationDidFinishLaunching`, after the existing `QueryNotifier.shared.registerCategories()` call and before showing the main window:

```swift
UpdateChecker.shared.start()
```

No preference gating at the call site — `checkNow()` gates internally on `AppStateManager.shared.settings.checkForUpdates`. The timer always runs (cheap), but HTTP calls are suppressed when the user opts out.

## Data Flow

```
applicationDidFinishLaunching
  ├─ QueryNotifier.registerCategories()     // registers both QUERY_COMPLETED and UPDATE_AVAILABLE
  └─ UpdateChecker.start()
       ├─ schedule 6h repeating Timer
       └─ Task { await checkNow() }         // initial check

checkNow()
  ├─ if !settings.checkForUpdates → return
  ├─ if lastCheckedAt < 24h ago → return (rate limit)
  ├─ URLSession GET /releases/latest
  ├─ parse tag_name
  ├─ compare to Bundle.main.shortVersion
  ├─ if newer AND != lastNotifiedVersion:
  │    QueryNotifier.postUpdateAvailableNotification(...)
  │    lastNotifiedVersion = tag_name
  └─ lastCheckedAt = now   // only on success

User taps notification
  └─ QueryNotifier.didReceive
       switch categoryIdentifier:
         UPDATE_AVAILABLE + default  → NSWorkspace.open(releasesUrl)
         UPDATE_AVAILABLE + COPY     → NSPasteboard set "brew upgrade pharos"
         QUERY_COMPLETED + ...       → existing flow
```

## Error Handling

- **Network failure / timeout:** silent, debug log, no state update. Retries on next 6h tick.
- **GitHub 5xx or rate-limit (unlikely given cadence):** same as network failure.
- **JSON decode failure:** silent, debug log.
- **Unparseable `tag_name`:** treat as "not newer," silent.
- **Same version as last-notified:** silent (dedupe).
- **Same version as current bundle:** silent (no update).
- **`releasesUrl` missing from `userInfo` on tap:** silent (user's click does nothing; no crash).
- **Clipboard write failure:** `NSPasteboard` operations don't realistically fail on macOS; no handling needed.

## Accessibility

- Notification posting uses the existing `QueryNotifier` infrastructure, which already returns `[.banner, .list, .sound]` in `willPresent`. Same macOS-level accessibility treatment as query notifications.
- No new UI surfaces beyond the one settings-sheet checkbox, which is a standard `NSButton` checkbox — VoiceOver-compatible by default.

## Testing Plan

Manual, via the running app:

1. **No-update path:** With current version matching the latest GitHub release, launch the app. No notification. Verify via debug log that the check ran and returned "not newer." `lastCheckedAt` is set to "now."

2. **Update-available path:** Temporarily edit `CFBundleShortVersionString` in `Pharos/App/Info.plist` to `"0.0.1"` (below the latest release). Rebuild. Launch. Notification appears: title `"Pharos · Update available"`, body `"Version <X> is available. Current: 0.0.1."`. Restore `0.1.0` before committing.

3. **Tap (default):** Click the notification banner body (not an action). Default browser opens `https://github.com/NeodymiumPhish/Pharos/releases/tag/v<version>`.

4. **Copy action:** Expand the notification (long-press or the twirl-down), click "Copy brew command." Paste into terminal → verify `brew upgrade pharos`.

5. **Per-version dedupe:** With Info.plist still at `0.0.1`, restart the app within 24 hours. No second notification for the same `lastNotifiedVersion`.

6. **24h cache (rate limit):** Manually set `updateCheckerLastCheckedAt` in UserDefaults to now via `defaults write com.pharos.client updateCheckerLastCheckedAt -date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"`, then restart. Debug log shows "rate-limited, skipping HTTP." No request made.

7. **Settings toggle:** Open Settings → General. Uncheck "Check for updates in the background." Save. Restart. No HTTP call fires. Re-enable. Restart. Check fires (respecting 24h cache).

8. **Network failure:** Disconnect Wi-Fi. Launch the app. Debug log shows the URLSession error. No notification. No crash. Re-connect. Wait for the 6h tick (or restart after clearing `lastCheckedAt` in UserDefaults). Verify recovery.

9. **Malformed tag (best-effort):** If a non-semver tag can be induced (difficult without pushing a test release), verify the parser returns "not newer" and no notification fires.

10. **Two-category delegate:** Run a long query that fires a `QUERY_COMPLETED` notification. Verify that the existing tap-to-focus still works after the `didReceive` switch was extended.

## Open Questions

None at time of writing. Implementation plan will verify:
- The exact `AppSettings` mutation helper if `collectSettings()` is not directly mutable.
- Whether any additional General-tab grid reflow is needed to accommodate the new row.
