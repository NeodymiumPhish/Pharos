# Update-Available Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect newer stable releases of Pharos on GitHub at app launch (and every 6 hours thereafter), then post a macOS native notification whose default tap opens the release page and whose action button copies `brew upgrade pharos` to the clipboard.

**Architecture:** A new `UpdateChecker` singleton owns a 6-hour `Timer` + initial launch tick. Each tick calls `/repos/NeodymiumPhish/Pharos/releases/latest`, respects a 24h HTTP-call cache in `UserDefaults`, compares the returned `tag_name` to `Bundle.main.shortVersionString`, and delegates notification posting to a new `QueryNotifier.postUpdateAvailableNotification(...)` method. The existing `QueryNotifier` `UNUserNotificationCenterDelegate` is extended to dispatch on `categoryIdentifier` — `QUERY_COMPLETED` keeps its current behavior, `UPDATE_AVAILABLE` opens the URL on tap and copies the brew command on the action button. A single `checkForUpdates: bool` field on `AppSettings` (default true) toggles the feature.

**Tech Stack:** Swift / AppKit / Foundation (`URLSession`, `UserDefaults`, `NSWorkspace`, `NSPasteboard`), `UserNotifications`, Rust (serde for settings).

Design spec: [docs/superpowers/specs/2026-04-21-update-available-notifications-design.md](../specs/2026-04-21-update-available-notifications-design.md)

---

### Task 1: Add `check_for_updates` to Rust `AppSettings`

**Files:**
- Modify: `pharos-core/src/models/settings.rs`

Settings are stored as a JSON blob in SQLite (`app_settings.settings_json TEXT`), so `#[serde(default)]` handles migration transparently — no DB schema change.

- [ ] **Step 1: Add the field plus default function**

Open `pharos-core/src/models/settings.rs`. The current `AppSettings` struct (around lines 145-160) reads:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub theme: ThemeMode,
    pub editor: EditorSettings,
    pub query: QuerySettings,
    pub ui: UISettings,
    #[serde(default)]
    pub keyboard: KeyboardSettings,
    #[serde(default)]
    pub empty_folders: Vec<String>,
    #[serde(default)]
    pub null_display: NullDisplay,
    #[serde(default)]
    pub bool_display: BoolDisplay,
}
```

Replace with:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub theme: ThemeMode,
    pub editor: EditorSettings,
    pub query: QuerySettings,
    pub ui: UISettings,
    #[serde(default)]
    pub keyboard: KeyboardSettings,
    #[serde(default)]
    pub empty_folders: Vec<String>,
    #[serde(default)]
    pub null_display: NullDisplay,
    #[serde(default)]
    pub bool_display: BoolDisplay,
    #[serde(default = "default_check_for_updates")]
    pub check_for_updates: bool,
}

fn default_check_for_updates() -> bool { true }
```

Then find the `impl Default for AppSettings` block (around lines 162-175) and update it to include the new field:

```rust
impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            theme: ThemeMode::default(),
            editor: EditorSettings::default(),
            query: QuerySettings::default(),
            ui: UISettings::default(),
            keyboard: KeyboardSettings::default(),
            empty_folders: Vec::new(),
            null_display: NullDisplay::default(),
            bool_display: BoolDisplay::default(),
            check_for_updates: default_check_for_updates(),
        }
    }
}
```

- [ ] **Step 2: Build Rust core**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos/pharos-core && cargo build --release 2>&1 | tail -10`
Expected: `Finished release [optimized]` with no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
git add pharos-core/src/models/settings.rs
git commit -m "add-check-for-updates-field-to-rust-app-settings"
```

---

### Task 2: Mirror `checkForUpdates` in Swift `AppSettings`

**Files:**
- Modify: `Pharos/Models/Settings.swift`

- [ ] **Step 1: Add the field**

Open `Pharos/Models/Settings.swift`. Current `AppSettings` struct (around lines 96-105) reads:

```swift
struct AppSettings: Codable {
    var theme: ThemeMode = .auto
    var editor: EditorSettings = EditorSettings()
    var query: QuerySettings = QuerySettings()
    var ui: UISettings = UISettings()
    var keyboard: KeyboardSettings = KeyboardSettings()
    var emptyFolders: [String] = []
    var nullDisplay: NullDisplay = .uppercase
    var boolDisplay: BoolDisplay = .trueFalse
}
```

Replace with:

```swift
struct AppSettings: Codable {
    var theme: ThemeMode = .auto
    var editor: EditorSettings = EditorSettings()
    var query: QuerySettings = QuerySettings()
    var ui: UISettings = UISettings()
    var keyboard: KeyboardSettings = KeyboardSettings()
    var emptyFolders: [String] = []
    var nullDisplay: NullDisplay = .uppercase
    var boolDisplay: BoolDisplay = .trueFalse
    var checkForUpdates: Bool = true
}
```

(Swift's synthesized `Codable` decodes old JSON without the key by using the default. The Rust side normalizes missing keys via `#[serde(default)]` before handing JSON to Swift, so Swift never sees incomplete JSON in practice — but the default is correct defense-in-depth.)

- [ ] **Step 2: Build**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/Settings.swift
git commit -m "mirror-check-for-updates-in-swift-app-settings"
```

---

### Task 3: Add "Check for updates" row to Settings sheet General tab

**Files:**
- Modify: `Pharos/Sheets/SettingsSheet.swift`

The General tab currently has three rows: theme, null display, bool display. We add a fourth row below with a `NSButton` checkbox.

- [ ] **Step 1: Declare the checkbox control**

Find the `// General` controls block (around lines 9-10). Current:

```swift
    // General
    private let themeControl = NSSegmentedControl()
```

There are likely other private let declarations below for `nullDisplayPopup`, `boolDisplayPopup`. Find the block that declares `themeControl` and any adjacent General-tab controls. Add the new checkbox after the last General-tab control (before the `// Editor` or `// Query` marker). The exact line is after the `NSPopUpButton`/`NSSegmentedControl` declarations for the other General-tab controls — grep for `nullDisplayPopup` to find the spot.

Add this line:

```swift
    private let checkForUpdatesCheck = NSButton(checkboxWithTitle: "Check for updates in the background", target: nil, action: nil)
```

- [ ] **Step 2: Add the row to the General tab grid**

Find `makeGeneralTab()` (around line 91). The current grid is:

```swift
        let grid = NSGridView(views: [
            [themeLabel, themeControl],
            [nullLabel, nullDisplayPopup],
            [boolLabel, boolDisplayPopup],
        ])
```

Replace with:

```swift
        let grid = NSGridView(views: [
            [themeLabel, themeControl],
            [nullLabel, nullDisplayPopup],
            [boolLabel, boolDisplayPopup],
            [NSGridCell.emptyContentView, checkForUpdatesCheck],
        ])
```

- [ ] **Step 3: Read the value in `populateFromSettings`**

Find the `// General` block inside `populateFromSettings()` (around lines 236-250). The section currently ends with the `boolDisplay` lookup:

```swift
        if let idx = BoolDisplay.allCases.firstIndex(of: settings.boolDisplay) {
            boolDisplayPopup.selectItem(at: idx)
        }
```

Add immediately after (still inside the General block, before the `// Editor` comment):

```swift
        checkForUpdatesCheck.state = settings.checkForUpdates ? .on : .off
```

- [ ] **Step 4: Write the value in `collectSettings`**

Find `collectSettings()` (around line 276). It has a `// General` block after `var s = settings` — grep for `s.theme = .auto` to locate. The General block ends after the `s.nullDisplay` and `s.boolDisplay` assignments (or similar). Add immediately after:

```swift
        s.checkForUpdates = checkForUpdatesCheck.state == .on
```

(Place it inside the General section, before `// Editor` or similar block marker.)

- [ ] **Step 5: Build**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Pharos/Sheets/SettingsSheet.swift
git commit -m "add-check-for-updates-checkbox-to-general-settings"
```

---

### Task 4: Extend `QueryNotifier` with UPDATE_AVAILABLE category, post method, and delegate routing

**Files:**
- Modify: `Pharos/Core/QueryNotifier.swift`

The existing `QueryNotifier` currently handles only the `QUERY_COMPLETED` category. We extend it to also register `UPDATE_AVAILABLE`, add a new public `postUpdateAvailableNotification` method, and dispatch on `categoryIdentifier` in `didReceive`.

- [ ] **Step 1: Add new static identifiers**

Find the three existing static identifiers near the top of the class (around lines 15-20):

```swift
    /// Notification category identifier registered at launch.
    static let categoryIdentifier = "QUERY_COMPLETED"
    /// Identifier for the inline "Dismiss" action.
    static let dismissActionIdentifier = "DISMISS"
    /// Posted when the user taps the notification body (default action).
    /// `userInfo["tabId"]` carries the String tab identifier.
    static let activateTabNotification = Notification.Name("pharosActivateTab")
```

Add these below:

```swift
    /// Notification category for update-available notifications.
    static let updateCategoryIdentifier = "UPDATE_AVAILABLE"
    /// Identifier for the "Copy brew command" action on update notifications.
    static let copyBrewCommandActionIdentifier = "COPY_BREW_COMMAND"
    /// Command copied to the clipboard on the "Copy brew command" action.
    static let brewUpgradeCommand = "brew upgrade pharos"
```

- [ ] **Step 2: Register the new category in `registerCategories`**

Current `registerCategories()` (around lines 35-51):

```swift
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
```

Replace with:

```swift
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
```

- [ ] **Step 3: Add `postUpdateAvailableNotification` public method**

Add this new public method inside the main `QueryNotifier` class (placement: right after `notifyQueryCompleted` ends, before the `// MARK: - Authorization` marker — grep for `// MARK: - Authorization` to find the spot):

```swift
    /// Post an update-available notification. Applies the same authorization gate
    /// as `notifyQueryCompleted` but no other gates (the caller is responsible for
    /// rate-limiting and per-version dedupe).
    @MainActor
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
```

- [ ] **Step 4: Dispatch on `categoryIdentifier` in `didReceive`**

Current delegate method (around lines 172-193):

```swift
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
```

Replace with:

```swift
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
```

- [ ] **Step 5: Build**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Pharos/Core/QueryNotifier.swift
git commit -m "extend-query-notifier-with-update-available-category"
```

---

### Task 5: Create `UpdateChecker`

**Files:**
- Create: `Pharos/Core/UpdateChecker.swift`

- [ ] **Step 1: Create the file**

Create `Pharos/Core/UpdateChecker.swift` with this content:

```swift
import AppKit
import Foundation

/// Polls GitHub for newer stable releases of Pharos and posts a macOS
/// notification (via `QueryNotifier.postUpdateAvailableNotification`) when a
/// newer version is available.
///
/// Behavior:
/// - Fires one check at launch and schedules a 6-hour repeating timer.
/// - Skips the HTTP call if `settings.checkForUpdates` is false.
/// - Rate-limits the HTTP call to at most once per 24 hours (via UserDefaults).
/// - Posts at most one notification per unique new version (per-version dedupe).
/// - Silently ignores network / decode / version-parse failures; only successful
///   calls update the `lastCheckedAt` timestamp.
final class UpdateChecker {

    static let shared = UpdateChecker()

    private static let apiURL = URL(string: "https://api.github.com/repos/NeodymiumPhish/Pharos/releases/latest")!
    private static let checkIntervalSeconds: TimeInterval = 6 * 3600
    private static let httpCacheSeconds: TimeInterval = 24 * 3600
    private static let requestTimeoutSeconds: TimeInterval = 10

    private static let lastCheckedAtKey = "updateCheckerLastCheckedAt"
    private static let lastNotifiedVersionKey = "updateCheckerLastNotifiedVersion"

    private var timer: Timer?

    private init() {}

    /// Start the periodic check. Safe to call multiple times (no-ops if already started).
    func start() {
        guard timer == nil else { return }
        Task { await checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkIntervalSeconds, repeats: true) { _ in
            Task { await UpdateChecker.shared.checkNow() }
        }
    }

    /// Run one check now, respecting the settings toggle and 24h rate limit.
    func checkNow() async {
        let settings = await MainActor.run { AppStateManager.shared.settings }
        guard settings.checkForUpdates else { return }

        if let lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedAtKey) as? Date,
           Date().timeIntervalSince(lastCheckedAt) < Self.httpCacheSeconds {
            NSLog("[UpdateChecker] Rate-limited (last check < 24h ago); skipping HTTP.")
            return
        }

        let latest: GitHubRelease
        do {
            latest = try await fetchLatestRelease()
        } catch {
            NSLog("[UpdateChecker] fetch failed: \(error)")
            return
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckedAtKey)

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        guard let currentComponents = Self.parseVersion(currentVersion),
              let latestComponents = Self.parseVersion(latest.tag_name) else {
            NSLog("[UpdateChecker] could not parse current=\(currentVersion) or latest=\(latest.tag_name); skipping.")
            return
        }
        guard latestComponents > currentComponents else { return }

        let lastNotified = UserDefaults.standard.string(forKey: Self.lastNotifiedVersionKey)
        guard lastNotified != latest.tag_name else {
            NSLog("[UpdateChecker] Already notified for \(latest.tag_name); skipping.")
            return
        }

        await MainActor.run {
            QueryNotifier.shared.postUpdateAvailableNotification(
                newVersion: latest.tag_name,
                currentVersion: currentVersion,
                releasesUrl: latest.html_url
            )
            UserDefaults.standard.set(latest.tag_name, forKey: Self.lastNotifiedVersionKey)
        }
    }

    // MARK: - HTTP

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.apiURL, timeoutInterval: Self.requestTimeoutSeconds)
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        request.setValue("Pharos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "UpdateChecker", code: status, userInfo: [NSLocalizedDescriptionKey: "Non-2xx response: \(status)"])
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Version parsing

    /// Parse a version string (with optional leading 'v' or 'V') into a 3-element `[major, minor, patch]`.
    /// Returns nil if parsing fails for any segment.
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = raw
        if let first = s.first, first == "v" || first == "V" {
            s = String(s.dropFirst())
        }
        let parts = s.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var result: [Int] = []
        for i in 0..<3 {
            guard let n = Int(parts[i]) else { return nil }
            result.append(n)
        }
        return result
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. XcodeGen picks up the new file automatically.

- [ ] **Step 3: Commit**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
git add Pharos/Core/UpdateChecker.swift Pharos.xcodeproj
git commit -m "add-update-checker-for-github-release-polling"
```

---

### Task 6: Wire `AppDelegate` to start the update checker

**Files:**
- Modify: `Pharos/App/AppDelegate.swift`

- [ ] **Step 1: Call `UpdateChecker.shared.start()` at launch**

In `Pharos/App/AppDelegate.swift`, find the existing `applicationDidFinishLaunching` method. Locate the block that registers `QueryNotifier` categories and adds the tab-activation observer. Current code (around lines 35-45):

```swift
        // Register query-completion notification category and delegate.
        QueryNotifier.shared.registerCategories()

        // Listen for notification taps that request tab activation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateTabNotification(_:)),
            name: QueryNotifier.activateTabNotification,
            object: nil
        )
```

Immediately after this block (before `// Show the main window`), add:

```swift

        // Start the background update checker. It gates internally on the
        // `checkForUpdates` setting, so no conditional is needed here.
        UpdateChecker.shared.start()
```

- [ ] **Step 2: Build**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Pharos/App/AppDelegate.swift
git commit -m "start-update-checker-from-app-delegate"
```

---

### Task 7: Manual verification

**Files:** None (manual testing only).

- [ ] **Step 1: Build and launch**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build
open Pharos.xcodeproj   # then Cmd+R
```

- [ ] **Step 2: No-update path (current version >= latest)**

With `Pharos/App/Info.plist` `CFBundleShortVersionString` set to whatever matches or exceeds the latest GitHub release tag (e.g. `0.1.0` if `v0.1.0` is the latest), launch the app and watch the Xcode console. Expected: an `NSLog` line like `[UpdateChecker] Rate-limited...` on subsequent launches within 24h, and no notification posted at any time. First launch within 24h fires the HTTP call but posts no notification (current ≥ latest).

- [ ] **Step 3: Update-available path**

Edit `Pharos/App/Info.plist`. Change:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
```

to:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
```

Clear the rate-limit UserDefaults so the test runs the HTTP check:

```bash
defaults delete com.pharos.client updateCheckerLastCheckedAt
defaults delete com.pharos.client updateCheckerLastNotifiedVersion
```

Rebuild and launch. Expected: after a short delay, a notification banner appears with:
- Title: `Pharos · Update available`
- Body: `Version v<latest> is available. Current: 0.0.1.` (or similar — `tag_name` is used verbatim)

**Important:** revert `Info.plist` to `0.1.0` before committing any of your test-related changes.

- [ ] **Step 4: Tap behavior (default action)**

With the notification still visible (from Step 3), click the notification body (not "Copy brew command"). Expected: the default browser opens the release page, e.g. `https://github.com/NeodymiumPhish/Pharos/releases/tag/v0.1.0`.

- [ ] **Step 5: Copy action**

Re-trigger the notification (clear the `updateCheckerLastNotifiedVersion` key, then reload Info.plist to 0.0.1 if you reverted it, or simply wait for the next scheduled check after clearing the defaults). Expand the notification in Notification Center (click "Options..." or hover for action buttons), click "Copy brew command." Paste into a terminal. Expected: `brew upgrade pharos`.

- [ ] **Step 6: Per-version dedupe**

After a notification fires in Step 3, leave Info.plist at `0.0.1` (or restore it to `0.1.0`). Restart the app within 24h. Expected: no second notification for the same version. Debug log shows `Already notified for <tag>; skipping.` if you cleared the HTTP cache, or `Rate-limited...` otherwise.

- [ ] **Step 7: 24h rate limit**

Simulate a recent check by setting the timestamp UserDefault to "now":

```bash
defaults write com.pharos.client updateCheckerLastCheckedAt -date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
```

Restart the app. Expected: debug log `Rate-limited (last check < 24h ago); skipping HTTP.` — no HTTP request made. No notification even if Info.plist is set to a stale version.

- [ ] **Step 8: Settings toggle**

Open Settings → General. Uncheck "Check for updates in the background." Save. Clear both UserDefaults keys:

```bash
defaults delete com.pharos.client updateCheckerLastCheckedAt
defaults delete com.pharos.client updateCheckerLastNotifiedVersion
```

Restart the app. Expected: no HTTP request, no notification, no log about rate-limiting (the setting check returns early before the rate-limit check).

Re-enable the setting, save, clear the keys again, restart. Expected: check fires normally.

- [ ] **Step 9: Network failure**

Disable Wi-Fi (or block `api.github.com` via `/etc/hosts` or similar). Clear rate-limit keys. Restart the app. Expected: debug log shows a URLSession error, no notification, no crash. `lastCheckedAt` is NOT updated (so the next tick will retry). Re-enable network, wait for the 6h tick or restart after clearing the keys — check recovers.

- [ ] **Step 10: Coexistence with query notifications**

Run a long query that fires a `QUERY_COMPLETED` notification (e.g. `SELECT pg_sleep(10);` with app backgrounded). Verify the existing tap-to-focus-tab behavior still works after the `didReceive` extension. Also verify the "Dismiss" action on the query notification still has no side effects.

- [ ] **Step 11: Revert Info.plist to correct version**

Critical before any final commit. Confirm:

```bash
grep -A1 "CFBundleShortVersionString" Pharos/App/Info.plist
```

Expected output:

```
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
```

If not 0.1.0, restore it.

---

## Summary

**New files:** `Pharos/Core/UpdateChecker.swift` (~150 lines).
**Modified files:** `pharos-core/src/models/settings.rs`, `Pharos/Models/Settings.swift`, `Pharos/Sheets/SettingsSheet.swift`, `Pharos/Core/QueryNotifier.swift`, `Pharos/App/AppDelegate.swift`.
**Commits:** 6 atomic commits (one per implementation task).
**Dependencies added:** None. Uses `URLSession`, `UserDefaults`, `NSWorkspace`, `NSPasteboard` — all Foundation/AppKit.
**DB migrations:** None (settings remain a JSON blob; `#[serde(default)]` handles the new field).
