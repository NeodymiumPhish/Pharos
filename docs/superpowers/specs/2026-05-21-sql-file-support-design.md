# SQL File Support — Design

**Date:** 2026-05-21
**Status:** Draft for review

## Goal

Add three related capabilities to Pharos:

1. **SQL import** — open a `.sql` (or other plain-text) file into a new query editor tab. No execution.
2. **SQL export** — save the current editor buffer, a saved query, or all queries in a saved-queries folder to `.sql` file(s).
3. **External app integration** — register Pharos as a Launch Services handler so users can double-click `.sql` files, drag them onto the dock, or pick Pharos from Finder's "Open With" menu.

## Non-Goals

- "Run script" — executing every statement in a `.sql` file against the active connection. (Possible future work.)
- Exporting query *results* as SQL `INSERT` statements from arbitrary queries. (Already exists for table exports.)
- NSDocument architecture. Pharos remains a non-document-based app; `.sql` tabs are still query-editor tabs, just with a remembered source URL.
- Custom document icon. Use the system's generic SQL doc icon for now.

## User-Facing Behavior

### Opening files

- `File > Open…` (⌘O): `NSOpenPanel` filtered to UTIs conforming to `public.text`. Selecting a file opens it in a new editor tab in the frontmost window.
- Finder double-click on a `.sql` file: launches Pharos if needed, opens the file in a new tab.
- Finder "Open With > Pharos" on any plain-text file (`.sql`, `.txt`, `.md`, …): opens in a new tab.
- Drag one or more files onto the Pharos dock icon: opens each in its own new tab.
- If Pharos has no open window when a file is opened externally, the standard window is created first, then the tab is added.
- If there is no active database connection, the tab opens anyway in disconnected state. Editing and saving still work; running queries does not.
- Tab title is the file's basename without the `.sql` extension; for non-`.sql` files (e.g. `notes.txt`), include the extension for clarity.

### Saving files

The opened tab remembers its source `URL` so save semantics behave naturally:

- ⌘S on a file-backed tab: write back to the source URL (no prompt).
- ⌘S on a tab with no source URL: existing **Save Query** flow (saves to the saved-queries database). Behavior unchanged from today.
- ⌥⌘S always: **Export Query as SQL File…** — `NSSavePanel`, default extension `.sql`, default filename derived from the tab title.
- Closing a dirty file-backed tab: existing dirty-tab prompt; "Save" writes back to the source URL.

### Saved-query exports

Sidebar context menu additions:

- Right-click a saved query → **Export as SQL File…**
  Loads the query text, `NSSavePanel` with default filename = sanitized query name + `.sql`. Single-file collision: standard system Replace/Cancel prompt.
- Right-click a folder → **Export Folder as SQL Files…**
  `NSOpenPanel` configured as folder chooser. For each saved query whose `folder` matches the selected folder, writes `<chosen dir>/<sanitized name>.sql`.
  **Collision handling:** pre-scan all target paths *before* writing anything. If any collide with existing files, show one dialog: `"N of M files already exist. [Replace All] [Keep Both] [Cancel]"`. "Keep Both" appends ` (2)`, ` (3)`, … suffixes; "Replace All" overwrites; "Cancel" aborts the whole export.

### Filename sanitization

Used for default save filenames and for folder export:

- Replace `/`, `:`, `\0`, and other control characters with `_`.
- Strip leading `.` (avoid hidden files).
- If the result is empty, use `untitled`.
- Always append `.sql` (export surfaces only — the importer doesn't enforce extension).

## Architecture

### Components touched

| Component | Change |
|---|---|
| `Pharos/App/Info.plist` | Add `UTImportedTypeDeclarations` for `public.sql`; add two `CFBundleDocumentTypes` entries (SQL Owner, plain text Alternate) |
| `Pharos/App/AppDelegate.swift` | Implement `application(_:open:)`; route to `AppStateManager.openTextFile(at:)` |
| `Pharos/App/MainMenu` / menu setup | Add `File > Open…` (⌘O) and `File > Export Query as SQL File…` (⌥⌘S) |
| `Pharos/Core/AppStateManager.swift` | New `openTextFile(at: URL)` — ensures a main window exists, then delegates to the frontmost `ContentViewController` |
| `Pharos/ViewControllers/ContentViewController.swift` | New `openTextFile(at: URL)` that creates an editor tab with the file's contents and records `sourceURL` |
| `Pharos/Models/QueryTab.swift` | Add optional `sourceURL: URL?` field |
| `Pharos/ViewControllers/QueryEditorVC.swift` | ⌘S routes to write-back-to-source when `sourceURL != nil` |
| `Pharos/ViewControllers/SidebarViewController.swift` / saved-queries view | Context menu items for `Export as SQL File…` and `Export Folder as SQL Files…` |
| **New** `Pharos/Files/SQLFileWriter.swift` | Atomic write helper |
| **New** `Pharos/Files/SavedQueryFilename.swift` | Pure-function sanitization + collision resolution |

### Data flow

```
                            +------------------------+
                            |  ContentViewController |
                            |  .openTextFile(at:URL) |
                            +-----------+------------+
                                        ^
                                        |
        ┌───────────────────────────────┼───────────────────────────────┐
        |                               |                               |
+-------+--------+         +------------+-------------+      +----------+----------+
| File > Open…   |         | AppDelegate              |      | (Future: open from |
| (NSOpenPanel)  |         | application(_:open:)     |      |  recent files)     |
+----------------+         | (Finder / dock / Open W.)|      +---------------------+
                           +--------------------------+
```

```
                              +----------------------+
                              |  SQLFileWriter.write |  (atomic, UTF-8, ensures .sql)
                              +-----------+----------+
                                          ^
                                          |
       ┌──────────────────────────────────┼──────────────────────────────────┐
       |                                  |                                  |
+------+------------------+   +-----------+-----------+   +------------------+----------+
| Editor: ⌘S / ⌥⌘S        |   | Sidebar: Export       |   | Sidebar: Export Folder      |
| (Save / Save As)        |   | saved query as SQL    |   | (multi-write, collision     |
+-------------------------+   +-----------------------+   |  pre-scan dialog)           |
                                                          +-----------------------------+
```

### `Info.plist` additions

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
      <array><string>sql</string></array>
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
    <array><string>public.sql</string></array>
  </dict>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Text File</string>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array><string>public.plain-text</string></array>
  </dict>
</array>
```

### `AppDelegate` hook

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    let textType = UTType.text
    for url in urls {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: textType) else { continue }
        AppStateManager.shared.openTextFile(at: url)  // creates window if needed, then routes to ContentVC
    }
}
```

### `QueryTab` model addition

```swift
struct QueryTab {
    // existing fields…
    var sourceURL: URL?  // nil for tabs not backed by a file on disk
}
```

## Error Handling

| Situation | Behavior |
|---|---|
| File unreadable / permission denied | `NSAlert`: "Couldn't open *filename*: *system error*." No tab created. |
| File isn't valid UTF-8 | `NSAlert`: "*filename* isn't a valid UTF-8 text file." No tab created. |
| File larger than 50 MB | Confirm sheet: "This file is *N* MB and may slow the editor. Open anyway?" Default = Cancel. |
| Write fails (single file) | `NSAlert` with system error string; tab stays open and dirty. |
| Folder export: target dir not writable | One alert before any writes; abort entire operation. |
| Folder export: per-file failures mid-batch | Continue through remaining queries, show a single summary alert at the end listing the failed filenames. |
| Dock receives a binary / non-text file | Silently ignored (we never claimed support for that type). |

## Testing

### Unit tests (Swift)

- `SavedQueryFilename.sanitize(_:)` — covers `/`, `:`, control chars, leading dot, empty string, already-valid name.
- Collision resolver — given existing filenames `["foo.sql"]` and a request to write `foo.sql`, returns `foo (2).sql`; chain through several collisions.

### Manual smoke test checklist

1. `File > Open…` → pick `example.sql` → new tab opens with contents; title is `example`.
2. Edit the tab → ⌘S → file on disk updates, tab not dirty.
3. ⌘S on a brand-new tab (no `sourceURL`) → existing Save Query flow appears (unchanged).
4. ⌥⌘S on any tab → `NSSavePanel` with default `.sql`; writing creates the file.
5. Right-click a saved query in the sidebar → **Export as SQL File…** → file lands at chosen path.
6. Right-click a saved-queries folder with 3 queries → **Export Folder as SQL Files…** → 3 files appear in the chosen directory.
7. Folder export with 2 colliding names → single dialog: Replace All / Keep Both / Cancel. Each choice behaves correctly.
8. Finder double-click on `~/Desktop/foo.sql` with Pharos closed → app launches, tab opens with contents.
9. Drag three `.sql` files onto the dock → three new tabs.
10. Right-click `foo.sql` in Finder → "Open With > Pharos" present; selecting opens a tab.
11. Right-click `notes.txt` in Finder → "Open With > Pharos" present (Alternate rank); selecting opens a tab titled `notes.txt`.
12. Drop a non-text file (e.g. a PNG) on the dock → silently ignored, no alert, no tab.
13. Open Pharos with no connection → use `File > Open…` → tab opens; "Run" is disabled but editing works.

### Verification commands

- `lsregister -dump | grep -i pharos` after a build to confirm Launch Services registered the document types.
- `mdls -name kMDItemContentTypeTree foo.sql` shows `public.sql` in the type tree after registration.

## Risks & Open Questions

- **Default handler aggression:** `LSHandlerRank = Owner` for `.sql` will make Pharos the default `.sql` opener on a fresh install when no other app is registered. On systems where users already have a preferred SQL editor, their setting wins. Confirmed acceptable.
- **50 MB threshold for "huge file" prompt** is a guess; revisit if real-world feedback says otherwise.
- **`public.sql` UTI** is community-conventional, not Apple-blessed. Importing it (rather than declaring it) is the standard mitigation — other apps that also import it interoperate correctly.

## Out of Scope (Future Work)

- Run-script feature (execute every statement in an opened `.sql` file).
- Export of query *results* as `INSERT` statements from arbitrary queries.
- Recent-files menu for `.sql` files.
- Custom document icon for `.sql` files.
- Hierarchical saved-query folders (currently flat by design).
