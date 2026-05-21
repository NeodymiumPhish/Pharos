# SQL File Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add open-`.sql`-into-editor support, save-as-`.sql` for editor / saved query / folder, and Launch Services registration so Finder, dock drag, and "Open With" work for plain-text files.

**Architecture:** Three entry points (menu, AppDelegate `application(_:open:)`, dock drop) converge on `AppStateManager.openTextFile(at:)`, which ensures a window exists then delegates to `ContentViewController.openTextFile(at:)`. Export is pure Swift via a single `SQLFileWriter` helper and a `SavedQueryFilename` sanitizer used by all three save surfaces. `Info.plist` declares an imported `public.sql` UTI plus two `CFBundleDocumentTypes` entries (SQL as Owner, plain-text as Alternate).

**Tech Stack:** Swift / AppKit, UniformTypeIdentifiers framework, NSOpenPanel/NSSavePanel, NSAlert. No Rust changes — text and saved-query metadata already cross FFI.

**Spec reference:** `docs/superpowers/specs/2026-05-21-sql-file-support-design.md`

**Testing note:** This project has no XCTest target today. Per project convention, verification is build-clean + a manual smoke test pass against the spec's checklist. Each task includes a one-line build verification command and (where it applies) a manual smoke step.

---

### Task 1: Add `sourceURL` to QueryTab model

**Files:**
- Modify: `Pharos/Models/QueryTab.swift`

- [ ] **Step 1: Add the field**

In `Pharos/Models/QueryTab.swift`, add a property to the `QueryTab` struct (after `paneId: String?`, before `init`):

```swift
    /// Filesystem URL this tab was opened from, if any. Set when the tab is
    /// opened from a `.sql` or other plain-text file; ⌘S writes back here.
    var sourceURL: URL?
```

- [ ] **Step 2: Verify the project still compiles**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds (no other code reads `sourceURL` yet so nothing should break).

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/QueryTab.swift
git commit -m "add sourceURL field to QueryTab for file-backed tabs"
```

---

### Task 2: Filename sanitizer + collision resolver

**Files:**
- Create: `Pharos/Files/SavedQueryFilename.swift`

- [ ] **Step 1: Create the helper**

Create `Pharos/Files/SavedQueryFilename.swift`:

```swift
import Foundation

/// Pure helpers for turning saved-query names into safe filesystem filenames
/// and resolving collisions deterministically.
enum SavedQueryFilename {

    /// Sanitize a saved-query name into a safe filesystem stem (no extension).
    ///
    /// - Replaces `/`, `:`, NUL, and ASCII control characters with `_`.
    /// - Strips leading dots so the file isn't hidden.
    /// - Returns `"untitled"` for empty input or input that sanitizes to empty.
    static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":", "\0":
                out.append("_")
            case _ where scalar.value < 0x20:
                out.append("_")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        while out.hasPrefix(".") {
            out.removeFirst()
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    /// Given a target directory and a desired filename `stem.sql`, return a
    /// unique URL by appending ` (2)`, ` (3)`, … to the stem until no
    /// collision exists. `taken` lets the caller block out filenames that
    /// will be written later in the same batch but don't exist on disk yet.
    static func uniquify(stem: String, in directory: URL, taken: inout Set<String>) -> URL {
        let fm = FileManager.default
        var candidate = "\(stem).sql"
        var n = 2
        while taken.contains(candidate) || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n)).sql"
            n += 1
        }
        taken.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
```

- [ ] **Step 2: Register the new file with XcodeGen and regenerate**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate
```

(XcodeGen picks up files from disk via the `sources:` glob in `project.yml`; no edit needed unless this command fails.)

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Eyeball-verify the sanitizer**

The helper is pure. Sanity-check by reading the cases in step 1 against these expected outputs (no test harness — just confirm the logic by inspection):

| Input | Expected output |
|---|---|
| `"foo"` | `"foo"` |
| `"a/b:c"` | `"a_b_c"` |
| `".hidden"` | `"hidden"` |
| `"..wat"` | `"wat"` |
| `""` | `"untitled"` |
| `"   "` | `"untitled"` |
| `"\u{0007}beep"` | `"_beep"` |

- [ ] **Step 5: Commit**

```bash
git add Pharos/Files/SavedQueryFilename.swift Pharos.xcodeproj
git commit -m "add SavedQueryFilename sanitize/uniquify helpers"
```

---

### Task 3: Atomic SQL file writer

**Files:**
- Create: `Pharos/Files/SQLFileWriter.swift`

- [ ] **Step 1: Create the writer**

Create `Pharos/Files/SQLFileWriter.swift`:

```swift
import Foundation

/// Atomic UTF-8 writer for text files. Used by every save-as-SQL surface so
/// failure handling stays in one place.
enum SQLFileWriter {

    /// Writes `text` to `url` atomically as UTF-8.
    ///
    /// Throws the underlying `NSError` from `Data.write` on failure (caller
    /// shows the alert).
    static func write(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: [.atomic])
    }
}
```

- [ ] **Step 2: Regenerate project and build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Files/SQLFileWriter.swift Pharos.xcodeproj
git commit -m "add SQLFileWriter atomic UTF-8 helper"
```

---

### Task 4: `ContentViewController.openTextFile(at:)`

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 1: Add the method**

Append a new extension at the bottom of `Pharos/ViewControllers/ContentViewController.swift`:

```swift
// MARK: - Open Text File

extension ContentViewController {

    /// Maximum file size we'll open without prompting (50 MB).
    private static let openFileSizeLimit: Int64 = 50 * 1024 * 1024

    /// Open a plain-text or `.sql` file as a new editor tab.
    ///
    /// Reads `url` synchronously (called from the main thread), shows a
    /// confirmation if the file is unusually large, alerts on read or
    /// decode failure, and on success creates a new tab in the focused
    /// pane with the file's contents and the URL recorded as `sourceURL`.
    @objc func openTextFile(at url: URL) {
        let fm = FileManager.default

        // Size guard.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > Self.openFileSizeLimit {
            let mb = Double(size.int64Value) / (1024 * 1024)
            let alert = NSAlert()
            alert.messageText = "Open large file?"
            alert.informativeText = String(format: "%@ is %.1f MB and may slow the editor.", url.lastPathComponent, mb)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Anyway")
            // First button (Cancel) is the default.
            if alert.runModal() != .alertSecondButtonReturn { return }
        }

        // Read and decode.
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Tab title: drop `.sql` for cleanliness; keep other extensions visible.
        let name: String
        if url.pathExtension.lowercased() == "sql" {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = url.lastPathComponent
        }

        let tab = stateManager.createTab(sql: text, name: name)
        stateManager.updateTab(id: tab.id) { $0.sourceURL = url }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "add ContentViewController.openTextFile(at:)"
```

---

### Task 5: `AppStateManager.openTextFile(at:)` window-ensuring entry point

**Files:**
- Modify: `Pharos/Core/AppStateManager.swift`

- [ ] **Step 1: Add the helper**

Append at the bottom of `AppStateManager.swift` (inside the class):

```swift
    /// Open a file as a new editor tab. Ensures the main window exists
    /// and is frontmost, then routes to its `ContentViewController`.
    ///
    /// This is the single entry point used by `File > Open…`,
    /// `application(_:open:)`, and any future drag-to-dock handlers.
    @MainActor
    func openTextFile(at url: URL) {
        let app = NSApp.delegate as? AppDelegate
        if app?.mainWindowController == nil {
            // App launched via file-open with no window yet — create one.
            app?.mainWindowController = MainWindowController()
        }
        guard let controller = app?.mainWindowController else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Walk the split-view children to find the ContentViewController.
        guard let split = controller.contentViewController as? PharosSplitViewController else { return }
        for item in split.splitViewItems {
            if let content = item.viewController as? ContentViewController {
                content.openTextFile(at: url)
                return
            }
        }
    }
```

- [ ] **Step 2: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Core/AppStateManager.swift
git commit -m "add AppStateManager.openTextFile(at:) entry point"
```

---

### Task 6: `File > Open…` menu item

**Files:**
- Modify: `Pharos/App/MainMenu.swift`
- Modify: `Pharos/App/AppDelegate.swift`

- [ ] **Step 1: Add the menu action on AppDelegate**

In `Pharos/App/AppDelegate.swift`, add this method to the `AppDelegate` class (anywhere inside the class body):

```swift
    @MainActor
    @objc func menuOpenSQLFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a SQL or text file to open"
        if let sqlType = UTType("public.sql") {
            panel.allowedContentTypes = [sqlType, .text, .plainText]
        } else {
            panel.allowedContentTypes = [.text, .plainText]
        }
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppStateManager.shared.openTextFile(at: url)
            }
        }
    }
```

At the top of `AppDelegate.swift`, ensure `import UniformTypeIdentifiers` is present (add it after `import CPharosCore`).

- [ ] **Step 2: Wire the menu item**

In `Pharos/App/MainMenu.swift`, in the File menu block, add `Open…` immediately after the `New Connection...` line:

Find this block:

```swift
        fileMenu.addItem(withTitle: "New Connection...", action: #selector(MainWindowController.showAddConnectionSheet), keyEquivalent: "n")
        fileMenu.addItem(.separator())
```

Replace with:

```swift
        fileMenu.addItem(withTitle: "New Connection...", action: #selector(MainWindowController.showAddConnectionSheet), keyEquivalent: "n")

        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(AppDelegate.menuOpenSQLFile(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]

        fileMenu.addItem(.separator())
```

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

1. Run the app in Xcode (Cmd+R).
2. `File > Open…` (or ⌘O) — file panel appears.
3. Pick any `.sql` or `.txt` file. New tab opens with its contents; tab title matches the file's basename.

- [ ] **Step 5: Commit**

```bash
git add Pharos/App/MainMenu.swift Pharos/App/AppDelegate.swift
git commit -m "add File > Open… (⌘O) to load a .sql or text file into a new tab"
```

---

### Task 7: AppDelegate `application(_:open:)`

**Files:**
- Modify: `Pharos/App/AppDelegate.swift`

- [ ] **Step 1: Implement the hook**

In `Pharos/App/AppDelegate.swift`, add this method to the `AppDelegate` class:

```swift
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        let textType = UTType.text
        for url in urls {
            let conforms: Bool
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                conforms = type.conforms(to: textType)
            } else {
                // Fallback: trust the extension if Launch Services hasn't
                // populated a UTI yet (rare on first launch after install).
                conforms = ["sql", "txt", "md"].contains(url.pathExtension.lowercased())
            }
            guard conforms else { continue }
            AppStateManager.shared.openTextFile(at: url)
        }
    }
```

- [ ] **Step 2: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds. (External-app smoke test happens after Task 8 registers the UTIs.)

- [ ] **Step 3: Commit**

```bash
git add Pharos/App/AppDelegate.swift
git commit -m "wire application(_:open:) to AppStateManager.openTextFile"
```

---

### Task 8: `Info.plist` UTI + CFBundleDocumentTypes

**Files:**
- Modify: `Pharos/App/Info.plist`

- [ ] **Step 1: Add the UTI declarations**

In `Pharos/App/Info.plist`, add these two top-level keys (inside the outer `<dict>`, alphabetical placement is conventional but not required):

```xml
<key>UTImportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>public.sql</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.source-code</string>
            <string>public.plain-text</string>
        </array>
        <key>UTTypeDescription</key>
        <string>SQL Script</string>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>sql</string>
            </array>
            <key>public.mime-type</key>
            <array>
                <string>application/sql</string>
                <string>text/x-sql</string>
            </array>
        </dict>
    </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>SQL Script</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSHandlerRank</key>
        <string>Owner</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>public.sql</string>
        </array>
    </dict>
    <dict>
        <key>CFBundleTypeName</key>
        <string>Text File</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSHandlerRank</key>
        <string>Alternate</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>public.plain-text</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 2: Verify the plist parses**

```bash
plutil -lint /Users/nfinn/Projects/aSideProjects/Pharos/Pharos/App/Info.plist
```

Expected: `Pharos/App/Info.plist: OK`.

- [ ] **Step 3: Clean build and re-register with Launch Services**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild clean build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
# Force Launch Services to pick up the freshly-built bundle:
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f -v build/Build/Products/Debug/Pharos.app 2>&1 | tail -5
```

Expected: build succeeds; `lsregister` prints a "registered" line for `Pharos.app`.

- [ ] **Step 4: Manual smoke test — external open**

1. Launch the freshly built app once (so Launch Services activates the registration), then quit.
2. In Finder, right-click a `.sql` file → **Open With** — Pharos should appear (and, for a fresh install, be the default).
3. Right-click a `.txt` file → **Open With** → **Other…** — Pharos should be selectable (Alternate rank).
4. Double-click a `.sql` file with Pharos closed — app launches and the file opens in a new tab.
5. Drag two or three `.sql` files onto the dock icon — each opens in its own tab.

- [ ] **Step 5: Commit**

```bash
git add Pharos/App/Info.plist
git commit -m "register Pharos as Launch Services handler for .sql and plain-text files"
```

---

### Task 9: ⌘S writes back to `sourceURL` for file-backed tabs

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 1: Update `menuSaveQuery` to fork on `sourceURL`**

Locate the existing `@objc func menuSaveQuery(_:)` (around line 1455) and replace its body with:

```swift
    @objc func menuSaveQuery(_: Any?) {
        guard let tab = stateManager.activeTab else { return }

        // File-backed tab: write back to the source URL.
        if let url = tab.sourceURL {
            let currentSQL = focusedPaneVC?.getSQL() ?? ""
            do {
                try SQLFileWriter.write(currentSQL, to: url)
                stateManager.updateTab(id: tab.id) {
                    $0.sql = currentSQL
                    $0.isDirty = false
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        // Saved-query-backed tab: update the saved query in place.
        if let savedId = tab.savedQueryId {
            let currentSQL = focusedPaneVC?.getSQL() ?? ""
            do {
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: currentSQL)
                _ = try PharosCore.updateSavedQuery(update)
                stateManager.updateTab(id: tab.id) { $0.sql = currentSQL }
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to update saved query: \(error)")
            }
            return
        }

        // New tab: prompt to save into the saved-queries store.
        presentSaveQuerySheet(tab: tab)
    }
```

- [ ] **Step 2: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 3: Manual smoke test**

1. ⌘O → pick `~/Desktop/test.sql` containing `SELECT 1;`.
2. Edit the tab to `SELECT 2;` — tab marks dirty.
3. ⌘S — no sheet appears. Inspect `~/Desktop/test.sql` via `cat`; it now contains `SELECT 2;`.
4. ⌘N for a brand-new tab → ⌘S → existing Save Query sheet appears (unchanged behavior).

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "wire ⌘S to write back to sourceURL for file-backed tabs"
```

---

### Task 10: ⌥⌘S "Export Query as SQL File…"

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`
- Modify: `Pharos/App/MainMenu.swift`

- [ ] **Step 1: Add the export action**

In `Pharos/ViewControllers/ContentViewController.swift`, add inside the existing `// MARK: - Save Query (Cmd+S)` extension (next to `menuSaveQueryAs`):

```swift
    @objc func menuExportEditorAsSQL(_: Any?) {
        guard let tab = stateManager.activeTab else { return }
        let text = focusedPaneVC?.getSQL() ?? ""

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("public.sql") ?? .plainText]
        panel.nameFieldStringValue = "\(SavedQueryFilename.sanitize(tab.name)).sql"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: view.window!) { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "sql" {
                url = url.appendingPathExtension("sql")
            }
            do {
                try SQLFileWriter.write(text, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
```

At the top of `ContentViewController.swift`, ensure `import UniformTypeIdentifiers` is present (add it after the other imports).

- [ ] **Step 2: Wire the menu item with ⌥⌘S**

In `Pharos/App/MainMenu.swift`, find the line:

```swift
        let saveQuery = fileMenu.addItem(withTitle: "Save Query…", action: #selector(ContentViewController.menuSaveQuery(_:)), keyEquivalent: "s")
        saveQuery.keyEquivalentModifierMask = [.command]
```

Add directly after it:

```swift
        let exportEditor = fileMenu.addItem(withTitle: "Export Query as SQL File…", action: #selector(ContentViewController.menuExportEditorAsSQL(_:)), keyEquivalent: "s")
        exportEditor.keyEquivalentModifierMask = [.command, .option]
```

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

1. Open any query in a tab.
2. `File > Export Query as SQL File…` (or ⌥⌘S) → save panel appears with `<tab name>.sql` pre-filled.
3. Confirm save; verify the file exists with the expected SQL.
4. Run on a tab whose name contains `/` or `:` — filename gets sanitized to `_`.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift Pharos/App/MainMenu.swift
git commit -m "add ⌥⌘S Export Query as SQL File…"
```

---

### Task 11: Context menu — Export single saved query as SQL

**Files:**
- Modify: `Pharos/ViewControllers/SavedQueriesVC.swift`

- [ ] **Step 1: Add the context-menu action**

In `Pharos/ViewControllers/SavedQueriesVC.swift`, add this method anywhere in the existing context-actions section (e.g. right after `contextCopySQL`):

```swift
    @objc private func contextExportQueryAsSQL(_: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("public.sql") ?? .plainText]
        panel.nameFieldStringValue = "\(SavedQueryFilename.sanitize(q.name)).sql"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "sql" {
                url = url.appendingPathExtension("sql")
            }
            do {
                try SQLFileWriter.write(q.sql, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
```

At the top of `SavedQueriesVC.swift`, ensure `import UniformTypeIdentifiers` is present.

- [ ] **Step 2: Add the menu item**

In `Pharos/ViewControllers/SavedQueriesVC.swift`, find this block inside `menuNeedsUpdate`:

```swift
        case .query:
            menu.addItem(withTitle: "Open in Tab", action: #selector(contextOpenInTab), keyEquivalent: "")
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
```

Replace with:

```swift
        case .query:
            menu.addItem(withTitle: "Open in Tab", action: #selector(contextOpenInTab), keyEquivalent: "")
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(withTitle: "Export as SQL File…", action: #selector(contextExportQueryAsSQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
```

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

1. Right-click a saved query → **Export as SQL File…** → save panel with sanitized name + `.sql`.
2. Save and verify the file content matches the saved query's SQL.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/SavedQueriesVC.swift
git commit -m "add Export as SQL File… context menu for saved queries"
```

---

### Task 12: Context menu — Export folder of saved queries

**Files:**
- Modify: `Pharos/ViewControllers/SavedQueriesVC.swift`

- [ ] **Step 1: Add the folder-export action**

In `Pharos/ViewControllers/SavedQueriesVC.swift`, add this method just after `contextExportQueryAsSQL`:

```swift
    @objc private func contextExportFolderAsSQL(_: Any?) {
        guard let node = clickedNode(), case .folder(let folderName) = node.kind else { return }

        // Enumerate queries that live in this folder.
        let queries = allQueries.filter { $0.folder == folderName }
        guard !queries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Folder is empty"
            alert.informativeText = "“\(folderName)” has no saved queries to export."
            alert.runModal()
            return
        }

        // Pick the target directory.
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.canCreateDirectories = true
        chooser.prompt = "Export"
        chooser.message = "Choose a folder to export \(queries.count) queries into"
        guard let window = view.window else { return }
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dir = chooser.url else { return }
            self?.runFolderExport(queries: queries, into: dir)
        }
    }

    /// Pre-scan for collisions, prompt once, then write all files.
    private func runFolderExport(queries: [SavedQuery], into dir: URL) {
        let fm = FileManager.default

        // Plan filenames (sanitized + collisions among queue itself).
        struct Plan { let sql: String; let stem: String; let target: URL; let exists: Bool }
        var planned: [Plan] = []
        var seenStems = Set<String>()
        for q in queries {
            var stem = SavedQueryFilename.sanitize(q.name)
            // Disambiguate duplicate sanitized names within this batch BEFORE
            // collision-checking against the filesystem so the user-facing
            // "exists" count is accurate.
            var unique = stem
            var n = 2
            while seenStems.contains(unique) {
                unique = "\(stem) (\(n))"
                n += 1
            }
            stem = unique
            seenStems.insert(stem)

            let target = dir.appendingPathComponent("\(stem).sql")
            planned.append(Plan(sql: q.sql, stem: stem, target: target, exists: fm.fileExists(atPath: target.path)))
        }

        let collisions = planned.filter { $0.exists }.count
        var mode: ExportCollisionMode = .replace  // only used if there are no collisions
        if collisions > 0 {
            let alert = NSAlert()
            alert.messageText = "\(collisions) of \(planned.count) files already exist"
            alert.informativeText = "Choose how to handle the existing files."
            alert.addButton(withTitle: "Replace All")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  mode = .replace
            case .alertSecondButtonReturn: mode = .keepBoth
            default: return  // Cancel
            }
        }

        // Write files; collect failures for a single end-of-run alert.
        var failures: [(name: String, error: String)] = []
        var takenInDir = Set<String>()
        // Seed `takenInDir` with the existing names when `keepBoth` so suffixes
        // don't collide with files already on disk.
        if mode == .keepBoth {
            takenInDir = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        }

        for p in planned {
            let url: URL
            switch mode {
            case .replace:
                url = p.target
            case .keepBoth:
                url = SavedQueryFilename.uniquify(stem: p.stem, in: dir, taken: &takenInDir)
            }
            do {
                try SQLFileWriter.write(p.sql, to: url)
            } catch {
                failures.append((name: url.lastPathComponent, error: error.localizedDescription))
            }
        }

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files couldn't be written"
            alert.informativeText = failures.map { "• \($0.name): \($0.error)" }.joined(separator: "\n")
            alert.runModal()
        }
    }

    private enum ExportCollisionMode {
        case replace
        case keepBoth
    }
```

- [ ] **Step 2: Add the menu item for folders**

In `menuNeedsUpdate`, find the `.folder` case:

```swift
        case .folder:
            menu.addItem(withTitle: "New Query", action: #selector(contextNewQuery), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
```

Replace with:

```swift
        case .folder:
            menu.addItem(withTitle: "New Query", action: #selector(contextNewQuery), keyEquivalent: "")
            menu.addItem(withTitle: "Export Folder as SQL Files…", action: #selector(contextExportFolderAsSQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
```

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

1. Create a folder in the saved-queries sidebar with three queries (e.g. `q1`, `q2`, `q3`).
2. Right-click the folder → **Export Folder as SQL Files…** → choose an empty directory.
3. Verify three files appear: `q1.sql`, `q2.sql`, `q3.sql`.
4. Repeat the export into the same directory.
   - Expected: one dialog appears: *"3 of 3 files already exist."*
   - Pick **Replace All**: files overwritten, no extra files created.
   - Repeat and pick **Keep Both**: three new files appear with ` (2)` suffix.
   - Repeat and pick **Cancel**: nothing changes on disk.
5. Right-click an empty folder → export → alert: "Folder is empty."

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/SavedQueriesVC.swift
git commit -m "add Export Folder as SQL Files… with pre-scan collision dialog"
```

---

### Task 13: Final smoke test pass

**Files:** (none; verification only)

- [ ] **Step 1: Run the full spec checklist end-to-end**

Walk through items 1–13 of the spec's manual smoke test checklist (`docs/superpowers/specs/2026-05-21-sql-file-support-design.md` → Testing section). For each, confirm the observed behavior matches the spec.

If any item fails, return to the relevant earlier task, fix, commit, and re-run.

- [ ] **Step 2: Verify Launch Services registration in a clean install simulation**

```bash
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$lsregister" -dump | grep -B1 -A6 "com.pharos.client" | head -40
"$lsregister" -dump | grep -i "public.sql" | head -10
```

Expected: Pharos appears in the dump; `public.sql` UTI is listed with Pharos as a claimant.

- [ ] **Step 3: No-op commit if needed**

If any fixes were made in step 1, they should already be committed by their respective tasks. Otherwise this task produces no new commit.

---

## Self-Review Notes

- **Spec coverage:** Every section of the spec maps to a task. UI surfaces 1–3 → Tasks 4–6, 9–12. External-app behavior → Tasks 7–8. Error-handling table → covered inline across Tasks 4, 9, 10, 11, 12. Filename sanitization → Task 2. ⌘S behavior matrix → Task 9.
- **`UTType` import:** Tasks 6, 10, 11 each call out the `import UniformTypeIdentifiers` addition since these files don't currently import it. Task 7 reuses the import from Task 6.
- **`allQueries` reference in Task 12:** This property already exists on `SavedQueriesVC` (used by the existing folder-rename code path in `cellView(_:didFinishEditingWithText:)`). No new field needed.
- **No XCTest target:** Pharos has no test target today; introducing one is outside this plan's scope. Verification is build-clean + manual smoke per the spec checklist.
