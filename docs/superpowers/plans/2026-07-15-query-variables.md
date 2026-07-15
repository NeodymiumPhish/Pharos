# Query Variables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user define per-tab query variables (`{{name}}`) in a collapsible right-docked panel and have Pharos substitute their values into the SQL at execution, validation, export, and copy time — while the editor keeps the token form.

**Architecture:** Substitution is pure client-side Swift (`VariableSubstitutor`) applied at the single execution choke point (`ContentViewController.performQuery`), at validation, and at editor SQL export. Variables live on `QueryTab` in memory; they persist by riding on the existing Saved Queries store (new JSON column). A new `QueryVariablesPanelVC` docks to the right of the editor inside `EditorPaneVC` using its existing frame-based layout, toggled by a right-aligned `curlybraces` toolbar button and resized by a drag divider (width in `UserDefaults`). `SQLTextView` gains a highlight pass that colors defined vs. undefined `{{…}}` tokens.

**Tech Stack:** Swift/AppKit, Rust (`pharos-core`) + SQLite via rusqlite, C FFI, XcodeGen. Pure-logic tests via standalone `swiftc` harness (no Xcode test target).

**Preamble — branch:** Before Task 1, create a working branch:
```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
git checkout -b feature/query-variables
```

---

## File Structure

**Created:**
- `Pharos/Models/QueryVariable.swift` — `QueryVariable`, `VariableType` (Foundation-only, Codable).
- `Pharos/Core/VariableSubstitutor.swift` — `render`, `containsTokens`, per-type formatting (Foundation-only).
- `Pharos/ViewControllers/QueryVariablesPanelVC.swift` — the variables panel UI.
- `Pharos/Views/ResizeDividerView.swift` — drag handle for panel resize.
- `PharosTests/VariableSubstitutorTests.swift` — pure-logic tests.
- `scripts/test-variable-substitutor.sh` — standalone test runner.

**Modified:**
- `Pharos/Models/QueryTab.swift` — add `variables`, `variablesPanelVisible`.
- `Pharos/Core/PharosCore+Query.swift` — (no change; documented for reference).
- `Pharos/ViewControllers/ContentViewController.swift` — substitute in `performQuery` + pre-flight guard; render `menuExportEditorAsSQL`; pass variables through save; restore variables on open-saved-query.
- `Pharos/ViewControllers/QueryEditorVC.swift` — skip validation when tokens present; `setVariableNames`.
- `Pharos/Editor/SQLTextView.swift` — theme colors + `variableNames` + Phase-3 highlight pass.
- `Pharos/ViewControllers/EditorPaneVC.swift` — toggle button, panel child, layout, divider, tab-switch rebind.
- `Pharos/Sheets/SaveQuerySheet.swift` — thread variables into create/replace.
- `Pharos/ViewControllers/SavedQueriesVC.swift` — render on copy/export.
- `Pharos/Models/SavedQuery.swift` — add `variables` to `SavedQuery`/`CreateSavedQuery`/`UpdateSavedQuery`.
- `pharos-core/src/models/saved_query.rs` — add `variables` to the three structs.
- `pharos-core/src/db/sqlite.rs` — column + migration + create/load/get/update.
- `project.yml` — regenerate via `xcodegen generate` for the new Swift files.

---

## Phase A — Core substitution engine (pure, TDD)

### Task 1: QueryVariable + VariableType model

**Files:**
- Create: `Pharos/Models/QueryVariable.swift`

- [ ] **Step 1: Write the model file**

```swift
import Foundation

/// How a variable's value is rendered when substituted into SQL.
enum VariableType: String, Codable, CaseIterable {
    case literal, text, number, bool, null

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Bool"
        case .null: return "Null"
        }
    }
}

/// A single user-defined query variable. `name` is stored WITHOUT the
/// surrounding `{{ }}` braces (e.g. "target_ip").
struct QueryVariable: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var value: String = ""
    var type: VariableType = .literal
}
```

- [ ] **Step 2: Commit**

```bash
git add Pharos/Models/QueryVariable.swift
git commit -m "feat: add QueryVariable / VariableType model"
```

---

### Task 2: VariableSubstitutor with tests (TDD)

**Files:**
- Create: `Pharos/Core/VariableSubstitutor.swift`
- Create: `PharosTests/VariableSubstitutorTests.swift`
- Create: `scripts/test-variable-substitutor.sh`

- [ ] **Step 1: Write the failing test file**

```swift
// Standalone test runner for VariableSubstitutor. Not part of the app target —
// compiled together with the implementation by scripts/test-variable-substitutor.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

func expectEqualArr(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func v(_ name: String, _ value: String, _ type: VariableType) -> QueryVariable {
    QueryVariable(name: name, value: value, type: type)
}

func runTests() {
    // Literal (raw) substitution
    expectEqual(
        VariableSubstitutor.render("orig_h = '{{ip}}'", with: [v("ip", "8.8.4.4", .literal)]).sql,
        "orig_h = '8.8.4.4'", "literal raw substitution")

    // Optional inner whitespace
    expectEqual(
        VariableSubstitutor.render("x = {{  ip  }}", with: [v("ip", "1", .literal)]).sql,
        "x = 1", "inner whitespace tolerated")

    // Text: quoted + escaped
    expectEqual(
        VariableSubstitutor.render("name = {{n}}", with: [v("n", "O'Brien", .text)]).sql,
        "name = 'O''Brien'", "text quoted + apostrophe escaped")

    // Number: valid stays bare
    expectEqual(
        VariableSubstitutor.render("port = {{p}}", with: [v("p", "443", .number)]).sql,
        "port = 443", "number valid bare")

    // Bool: normalized
    expectEqual(
        VariableSubstitutor.render("ok = {{b}}", with: [v("b", "YES", .bool)]).sql,
        "ok = true", "bool YES -> true")

    // Null: emits NULL, ignores value
    expectEqual(
        VariableSubstitutor.render("c = {{x}}", with: [v("x", "ignored", .null)]).sql,
        "c = NULL", "null emits NULL")

    // Unresolved: token left verbatim, name collected
    let unres = VariableSubstitutor.render("a = {{foo}}", with: [])
    expectEqual(unres.sql, "a = {{foo}}", "unresolved left verbatim")
    expectEqualArr(unres.unresolved, ["foo"], "unresolved name collected")

    // Invalid number: token left verbatim, invalid collected
    let inv = VariableSubstitutor.render("p = {{p}}", with: [v("p", "abc", .number)])
    expectEqual(inv.sql, "p = {{p}}", "invalid number left verbatim")
    expectTrue(inv.invalid.count == 1 && inv.invalid[0].name == "p", "invalid number collected")

    // Collision safety: emails / operators / casts / params untouched
    let safe = "email = 'admin@example.com' AND tags @> '{\"k\":1}' AND a::int = $1"
    expectEqual(VariableSubstitutor.render(safe, with: [v("k", "X", .literal)]).sql, safe,
                "no collision with emails/operators/casts/params")

    // Multiple + repeated
    expectEqual(
        VariableSubstitutor.render("{{a}}-{{b}}-{{a}}", with: [v("a", "1", .literal), v("b", "2", .literal)]).sql,
        "1-2-1", "multiple + repeated tokens")

    // containsTokens
    expectTrue(VariableSubstitutor.containsTokens("x = {{y}}"), "containsTokens true")
    expectTrue(!VariableSubstitutor.containsTokens("x = 'a@b'"), "containsTokens false")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
```

- [ ] **Step 2: Write the test runner script**

```bash
#!/bin/bash
# Standalone test runner for VariableSubstitutor — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-substitutor-tests \
  Pharos/Models/QueryVariable.swift \
  Pharos/Core/VariableSubstitutor.swift \
  PharosTests/VariableSubstitutorTests.swift \
  PharosTests/main.swift
/tmp/variable-substitutor-tests
```

Then make it executable:

```bash
chmod +x scripts/test-variable-substitutor.sh
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./scripts/test-variable-substitutor.sh`
Expected: FAIL to compile with "cannot find 'VariableSubstitutor' in scope" (implementation not written yet).

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

/// Renders token-form SQL (`{{name}}`) into executable SQL by substituting
/// user-defined variable values. Pure logic — no AppKit, unit-tested standalone.
enum VariableSubstitutor {

    struct Invalid: Equatable {
        let name: String
        let reason: String
    }

    struct Result: Equatable {
        var sql: String
        var unresolved: [String]   // token names present but not defined (dedup, in order)
        var invalid: [Invalid]     // defined but value failed type validation
    }

    /// `{{ name }}` — double braces, optional inner whitespace, identifier only.
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
    )

    /// SQL numeric literal: optional sign, integer/decimal (no exponent).
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"^[+-]?(\d+(\.\d+)?|\.\d+)$"#
    )

    private static let trueSet: Set<String> = ["true", "t", "1", "yes", "y"]
    private static let falseSet: Set<String> = ["false", "f", "0", "no", "n"]

    /// True if the text contains at least one `{{name}}` token.
    static func containsTokens(_ sql: String) -> Bool {
        let ns = sql as NSString
        return tokenRegex.firstMatch(in: sql, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func render(_ sql: String, with variables: [QueryVariable]) -> Result {
        // Last definition wins on duplicate names.
        var byName: [String: QueryVariable] = [:]
        for variable in variables { byName[variable.name] = variable }

        let ns = sql as NSString
        let full = NSRange(location: 0, length: ns.length)

        var out = ""
        var lastEnd = 0
        var unresolved: [String] = []
        var invalid: [Invalid] = []

        tokenRegex.enumerateMatches(in: sql, range: full) { match, _, _ in
            guard let match else { return }
            let whole = match.range
            let name = ns.substring(with: match.range(at: 1))

            // Text before this token, verbatim.
            out += ns.substring(with: NSRange(location: lastEnd, length: whole.location - lastEnd))
            lastEnd = whole.location + whole.length

            guard let variable = byName[name] else {
                if !unresolved.contains(name) { unresolved.append(name) }
                out += ns.substring(with: whole)  // leave token verbatim
                return
            }

            let formatted = format(variable)
            if let rendered = formatted.value {
                out += rendered
            } else {
                invalid.append(Invalid(name: name, reason: formatted.reason ?? "invalid value"))
                out += ns.substring(with: whole)  // leave token verbatim
            }
        }

        // Trailing text after the last token.
        out += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return Result(sql: out, unresolved: unresolved, invalid: invalid)
    }

    private static func format(_ variable: QueryVariable) -> (value: String?, reason: String?) {
        let raw = variable.value
        switch variable.type {
        case .literal:
            return (raw, nil)
        case .text:
            return ("'" + raw.replacingOccurrences(of: "'", with: "''") + "'", nil)
        case .number:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let ok = numberRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
            if ok { return (trimmed, nil) }
            return (nil, "not a valid number: \(raw.debugDescription)")
        case .bool:
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trueSet.contains(key) { return ("true", nil) }
            if falseSet.contains(key) { return ("false", nil) }
            return (nil, "not a valid boolean: \(raw.debugDescription)")
        case .null:
            return ("NULL", nil)
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-variable-substitutor.sh`
Expected: all lines `PASS ...` then `ALL PASSED`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Pharos/Core/VariableSubstitutor.swift PharosTests/VariableSubstitutorTests.swift scripts/test-variable-substitutor.sh
git commit -m "feat: add VariableSubstitutor with standalone tests"
```

---

## Phase B — Model wiring

### Task 3: Add variables to QueryTab

**Files:**
- Modify: `Pharos/Models/QueryTab.swift:48-51`

- [ ] **Step 1: Add the fields**

In `struct QueryTab`, after the `sourceURL` property (line 51), add:

```swift
    /// User-defined query variables for this tab (referenced as `{{name}}`).
    var variables: [QueryVariable] = []
    /// Whether the right-docked variables panel is shown for this tab.
    var variablesPanelVisible: Bool = false
```

No `init` change is needed — both have defaults.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/QueryTab.swift
git commit -m "feat: add per-tab variables + panel visibility to QueryTab"
```

---

## Phase C — Execution & validation substitution

### Task 4: Substitute in performQuery + pre-flight guard

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift:1122-1123` (inside `performQuery`)
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (add helper in the same file)

- [ ] **Step 1: Replace the SQL-trim lines with substitution + guard**

Replace exactly these two lines at 1122-1123:

```swift
        let sql = querySQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
```

with:

```swift
        let rendered = VariableSubstitutor.render(querySQL, with: activeTab.variables)
        if !rendered.unresolved.isEmpty || !rendered.invalid.isEmpty {
            presentVariableError(unresolved: rendered.unresolved, invalid: rendered.invalid, tabId: tabId)
            return
        }
        let sql = rendered.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
```

(`activeTab` and `tabId` are already in scope — see lines 1116-1119. Everything downstream already uses `sql`, so execution, `ResultTab.sql`, and history all receive the rendered string.)

- [ ] **Step 2: Add the pre-flight error helper**

Add this method inside the `performQuery`-owning class body (e.g. immediately after `performQuery`'s closing brace). It surfaces the problem and opens the panel so the user can fix it:

```swift
    /// Surface an unresolved/invalid-variable error before a query runs, and
    /// reveal the variables panel so the user can correct it.
    private func presentVariableError(
        unresolved: [String],
        invalid: [VariableSubstitutor.Invalid],
        tabId: String
    ) {
        var parts: [String] = []
        if !unresolved.isEmpty {
            parts.append("Undefined: " + unresolved.map { "{{\($0)}}" }.joined(separator: ", "))
        }
        for item in invalid {
            parts.append("\(item.name): \(item.reason)")
        }
        Toast.show(
            in: self.view,
            message: parts.joined(separator: " · "),
            style: .error,
            duration: 3.0
        )
        stateManager.updateTab(id: tabId) { $0.variablesPanelVisible = true }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`
(`presentVariableError` toggles `variablesPanelVisible`; the panel/layout wiring lands in Phase E — until then the toast still works.)

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: substitute query variables at execution + pre-flight guard"
```

---

### Task 5: Skip validation when tokens are present

**Files:**
- Modify: `Pharos/ViewControllers/QueryEditorVC.swift:546-552` (inside `validateSQL`)

**Why skip rather than substitute:** validation error positions map to the editor text; validating a rendered string of different length would misplace the underline markers. Queries containing tokens simply skip live syntax validation (they are validated for real at execution time).

- [ ] **Step 1: Add the token guard**

In `validateSQL(_ sql:)`, immediately after the existing early-return guard block (after line 552, before `do {`), add:

```swift
        // Skip live validation while unsubstituted variable tokens are present:
        // Postgres would flag `{{...}}` as a syntax error, and substituted-text
        // error offsets wouldn't map back to the editor's token-form text.
        guard !VariableSubstitutor.containsTokens(sql) else {
            await MainActor.run { self.clearErrorMarkers() }
            return
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/QueryEditorVC.swift
git commit -m "feat: skip live validation while variable tokens are present"
```

---

## Phase D — Editor highlighting

### Task 6: Theme colors + variableNames + Phase-3 highlight pass

**Files:**
- Modify: `Pharos/Editor/SQLTextView.swift:5-21` (SQLTheme)
- Modify: `Pharos/Editor/SQLTextView.swift:45-47` (theme property region — add variableNames)
- Modify: `Pharos/Editor/SQLTextView.swift:~100` (add token regex static)
- Modify: `Pharos/Editor/SQLTextView.swift:767-836` (highlightSyntax — add Phase 3)

- [ ] **Step 1: Add theme colors**

In `struct SQLTheme`, add two fields and values. Replace the struct's field list and `.default` with:

```swift
struct SQLTheme {
    let keyword: NSColor
    let function: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let type: NSColor
    let variable: NSColor           // defined {{name}}
    let variableUnresolved: NSColor // {{name}} with no definition

    static let `default` = SQLTheme(
        keyword: .systemBlue,
        function: .systemTeal,
        string: .systemGreen,
        number: .systemOrange,
        comment: .systemGray,
        type: .systemPurple,
        variable: .systemIndigo,
        variableUnresolved: .systemRed
    )
}
```

- [ ] **Step 2: Add the variableNames property**

Immediately after the `theme` property (line 45-47), add:

```swift
    /// Names (without braces) of variables defined for the active tab. Drives
    /// defined-vs-undefined coloring of `{{name}}` tokens. Re-highlights on change.
    var variableNames: Set<String> = [] {
        didSet {
            guard variableNames != oldValue else { return }
            highlightSyntax()
        }
    }
```

- [ ] **Step 3: Add the token regex static**

Near the other cached regex statics (after `numberRegex`, line 100), add:

```swift
    private static let variableTokenRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
    )
```

- [ ] **Step 4: Add Phase 3 inside highlightSyntax**

In `highlightSyntax()`, snapshot `variableNames` next to `themeSnapshot` (after line 780 `let themeSnapshot = theme`):

```swift
        let variableNamesSnapshot = variableNames
```

Then inside the `Task.detached` block, after the Phase 2 regex loop and before `await MainActor.run` (after line 828), add:

```swift
            // Phase 3: variable tokens `{{name}}`. Appended last so they win over
            // keyword/number coloring on overlap. Colored regardless of lex state
            // (variables are commonly written inside quotes, e.g. '{{ip}}').
            Self.variableTokenRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match else { return }
                let name = (text as NSString).substring(with: match.range(at: 1))
                let color = variableNamesSnapshot.contains(name)
                    ? themeSnapshot.variable
                    : themeSnapshot.variableUnresolved
                attrs.append(.init(range: match.range, color: color))
            }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Pharos/Editor/SQLTextView.swift
git commit -m "feat: highlight {{variable}} tokens (defined vs undefined)"
```

---

### Task 7: Push variableNames from QueryEditorVC

**Files:**
- Modify: `Pharos/ViewControllers/QueryEditorVC.swift` (add public setter)

- [ ] **Step 1: Add the setter on QueryEditorVC**

Add to the `// MARK: - Public API` section (near `getSQL()`, line 181):

```swift
    /// Set the variable names used for `{{token}}` highlighting.
    func setVariableNames(_ names: Set<String>) {
        textView.variableNames = names
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`
(The call sites that invoke `setVariableNames` are added in Task 10, when EditorPaneVC owns the panel.)

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/QueryEditorVC.swift
git commit -m "feat: expose setVariableNames on QueryEditorVC"
```

---

## Phase E — Panel UI + toolbar toggle

### Task 8: The variables panel view controller

**Files:**
- Create: `Pharos/ViewControllers/QueryVariablesPanelVC.swift`

**Behavior:** shows the tab's variables as rows (`{{`name`}}` field · value field · type popup · delete). Text edits update the in-memory model by `id` without rebuilding rows (preserving focus); add/delete rebuild the rows. Every mutation calls `onChange` with the full updated array.

- [ ] **Step 1: Write the panel VC**

```swift
import AppKit

/// Right-docked panel listing a tab's query variables.
final class QueryVariablesPanelVC: NSViewController {

    /// Called whenever the variable set changes (add / delete / edit).
    var onChange: (([QueryVariable]) -> Void)?

    private(set) var variables: [QueryVariable] = []
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()

    /// Replace the displayed variables (e.g. on tab switch). Rebuilds rows.
    func setVariables(_ vars: [QueryVariable]) {
        variables = vars
        rebuildRows()
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        self.view = container

        // Header: title + add button
        let title = NSTextField(labelWithString: "Variables")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add variable")
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.toolTip = "Add variable"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(addButton)

        // Rows in a vertical stack inside a scroll view
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        scrollView.contentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Left-edge separator so the panel reads as docked
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(scrollView)
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 22),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rowsStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])

        rebuildRows()
    }

    // MARK: - Rows

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for variable in variables {
            rowsStack.addArrangedSubview(makeRow(for: variable.id))
        }
        if variables.isEmpty {
            let empty = NSTextField(labelWithString: "No variables.\nClick + to add one.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.maximumNumberOfLines = 2
            rowsStack.addArrangedSubview(empty)
        }
    }

    private func makeRow(for id: UUID) -> NSView {
        let braceLead = NSTextField(labelWithString: "{{")
        braceLead.textColor = .tertiaryLabelColor
        let nameField = NSTextField()
        nameField.placeholderString = "name"
        nameField.stringValue = variables.first(where: { $0.id == id })?.name ?? ""
        nameField.identifier = NSUserInterfaceItemIdentifier("name:\(id.uuidString)")
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        let braceTrail = NSTextField(labelWithString: "}}")
        braceTrail.textColor = .tertiaryLabelColor

        let valueField = NSTextField()
        valueField.placeholderString = "value"
        valueField.stringValue = variables.first(where: { $0.id == id })?.value ?? ""
        valueField.identifier = NSUserInterfaceItemIdentifier("value:\(id.uuidString)")
        valueField.delegate = self
        valueField.translatesAutoresizingMaskIntoConstraints = false

        let typePopup = NSPopUpButton()
        for t in VariableType.allCases { typePopup.addItem(withTitle: t.displayName) }
        if let current = variables.first(where: { $0.id == id })?.type,
           let idx = VariableType.allCases.firstIndex(of: current) {
            typePopup.selectItem(at: idx)
        }
        typePopup.identifier = NSUserInterfaceItemIdentifier("type:\(id.uuidString)")
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        typePopup.controlSize = .small
        typePopup.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton()
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.identifier = NSUserInterfaceItemIdentifier("delete:\(id.uuidString)")
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSStackView(views: [braceLead, nameField, braceTrail, deleteButton])
        nameRow.orientation = .horizontal
        nameRow.spacing = 2
        let controlsRow = NSStackView(views: [valueField, typePopup])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 4

        let row = NSStackView(views: [nameRow, controlsRow])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            typePopup.widthAnchor.constraint(equalToConstant: 84),
        ])
        return row
    }

    private static func id(from identifier: NSUserInterfaceItemIdentifier?, prefix: String) -> UUID? {
        guard let raw = identifier?.rawValue, raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }

    // MARK: - Actions

    @objc private func addTapped() {
        variables.append(QueryVariable(name: "", value: "", type: .literal))
        rebuildRows()
        onChange?(variables)
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let id = Self.id(from: sender.identifier, prefix: "delete:") else { return }
        variables.removeAll { $0.id == id }
        rebuildRows()
        onChange?(variables)
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        guard let id = Self.id(from: sender.identifier, prefix: "type:"),
              let varIdx = variables.firstIndex(where: { $0.id == id }) else { return }
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < VariableType.allCases.count else { return }
        variables[varIdx].type = VariableType.allCases[idx]
        onChange?(variables)
    }
}

extension QueryVariablesPanelVC: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let id = Self.id(from: field.identifier, prefix: "name:"),
           let idx = variables.firstIndex(where: { $0.id == id }) {
            variables[idx].name = field.stringValue
            onChange?(variables)
        } else if let id = Self.id(from: field.identifier, prefix: "value:"),
                  let idx = variables.firstIndex(where: { $0.id == id }) {
            variables[idx].value = field.stringValue
            onChange?(variables)
        }
    }
}

/// Flipped clip view so the rows stack grows top-down inside the scroll view.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
```

- [ ] **Step 2: Regenerate project & build**

Run: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/QueryVariablesPanelVC.swift project.yml
git commit -m "feat: add QueryVariablesPanelVC"
```

---

### Task 9: ResizeDividerView drag handle

**Files:**
- Create: `Pharos/Views/ResizeDividerView.swift`

- [ ] **Step 1: Write the divider view**

```swift
import AppKit

/// A thin vertical drag handle. Reports horizontal drag deltas (in the parent's
/// coordinate space) via `onDrag`. Shows a resize cursor on hover.
final class ResizeDividerView: NSView {

    /// Called with the horizontal delta (points) as the user drags.
    /// Positive delta = dragged right.
    var onDrag: ((CGFloat) -> Void)?

    private var lastX: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let delta = x - lastX
        lastX = x
        onDrag?(delta)
    }
}
```

- [ ] **Step 2: Regenerate project & build**

Run: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Pharos/Views/ResizeDividerView.swift project.yml
git commit -m "feat: add ResizeDividerView drag handle"
```

---

### Task 10: Toolbar toggle + panel integration in EditorPaneVC

**Files:**
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift` (properties, setup, layout, toggle, rebind)

- [ ] **Step 1: Add stored properties**

After the connection/schema selector properties (near line 46), add:

```swift
    // Query variables
    private let variablesToggle = NSButton()
    private let variablesPanelVC = QueryVariablesPanelVC()
    private let variablesDivider = ResizeDividerView()
    private let variablesDividerWidth: CGFloat = 5
    private let variablesPanelMinWidth: CGFloat = 180
    private let variablesPanelMaxWidth: CGFloat = 600
    private let variablesPanelWidthKey = "QueryVariablesPanelWidth"

    private var variablesPanelWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: variablesPanelWidthKey)
            let value = stored == 0 ? 260 : CGFloat(stored)
            return min(max(value, variablesPanelMinWidth), variablesPanelMaxWidth)
        }
        set {
            let clamped = min(max(newValue, variablesPanelMinWidth), variablesPanelMaxWidth)
            UserDefaults.standard.set(Double(clamped), forKey: variablesPanelWidthKey)
        }
    }

    private var isVariablesPanelVisible: Bool {
        guard let tabId = lastActiveTabId,
              let tab = stateManager.tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.variablesPanelVisible
    }
```

- [ ] **Step 2: Configure the toggle button in setupEditorToolbar**

Inside `setupEditorToolbar()`, before the final `NSLayoutConstraint.activate([...])` call (line 546), add the button setup:

```swift
        // Variables panel toggle (right-aligned, not part of the leading stack)
        let varConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        variablesToggle.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Query Variables")?.withSymbolConfiguration(varConfig)
        variablesToggle.bezelStyle = .recessed
        variablesToggle.isBordered = false
        variablesToggle.toolTip = "Query Variables"
        variablesToggle.contentTintColor = .secondaryLabelColor
        variablesToggle.target = self
        variablesToggle.action = #selector(toggleVariablesPanel)
        variablesToggle.translatesAutoresizingMaskIntoConstraints = false
        editorToolbar.addSubview(variablesToggle)
```

Then add these to the `NSLayoutConstraint.activate([...])` array (alongside the existing entries):

```swift
            variablesToggle.widthAnchor.constraint(equalToConstant: 28),
            variablesToggle.heightAnchor.constraint(equalToConstant: 28),
            variablesToggle.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor, constant: -8),
            variablesToggle.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),
```

- [ ] **Step 3: Add the panel + divider as children in loadView**

In `loadView()`, after `addChild(editorVC)` (line 131) add:

```swift
        addChild(variablesPanelVC)
        variablesPanelVC.onChange = { [weak self] vars in
            self?.variablesDidChange(vars)
        }
        variablesDivider.onDrag = { [weak self] delta in
            self?.resizeVariablesPanel(byDelta: delta)
        }
```

And after `container.addSubview(editorVC.view)` (line 135) add:

```swift
        container.addSubview(variablesPanelVC.view)
        container.addSubview(variablesDivider)
        variablesPanelVC.view.isHidden = true
        variablesDivider.isHidden = true
```

- [ ] **Step 4: Lay out the panel + divider in viewDidLayout**

Replace the body of `viewDidLayout()` (lines 253-262) with:

```swift
    override func viewDidLayout() {
        super.viewDidLayout()
        // Non-flipped: y=0 is bottom. Tab bar + editor toolbar at top via Auto Layout.
        let editorHeight = max(0, view.bounds.height - totalHeaderHeight)
        let showPanel = isVariablesPanelVisible
        let panelW = showPanel ? variablesPanelWidth : 0
        let dividerW = showPanel ? variablesDividerWidth : 0
        let editorW = max(0, view.bounds.width - panelW - dividerW)

        editorVC.view.frame = NSRect(x: 0, y: 0, width: editorW, height: editorHeight)

        variablesDivider.isHidden = !showPanel
        variablesPanelVC.view.isHidden = !showPanel
        if showPanel {
            variablesDivider.frame = NSRect(x: editorW, y: 0, width: dividerW, height: editorHeight)
            variablesPanelVC.view.frame = NSRect(x: editorW + dividerW, y: 0, width: panelW, height: editorHeight)
        }
    }
```

- [ ] **Step 5: Add toggle / resize / change / rebind helpers**

Add these methods to `EditorPaneVC` (e.g. after `setupEditorToolbar`'s region):

```swift
    @objc private func toggleVariablesPanel() {
        guard let tabId = lastActiveTabId else { return }
        stateManager.updateTab(id: tabId) { $0.variablesPanelVisible.toggle() }
        syncVariablesPanel()
    }

    private func resizeVariablesPanel(byDelta delta: CGFloat) {
        // Dragging the divider left (negative delta) widens the panel.
        variablesPanelWidth = variablesPanelWidth - delta
        view.needsLayout = true
    }

    private func variablesDidChange(_ vars: [QueryVariable]) {
        guard let tabId = lastActiveTabId else { return }
        stateManager.updateTab(id: tabId) { $0.variables = vars }
        editorVC.setVariableNames(Set(vars.map { $0.name }.filter { !$0.isEmpty }))
    }

    /// Refresh the panel's data, visibility, toolbar tint, and editor highlighting
    /// from the active tab. Call on toggle and on tab switch.
    private func syncVariablesPanel() {
        let tab = lastActiveTabId.flatMap { id in stateManager.tabs.first(where: { $0.id == id }) }
        let vars = tab?.variables ?? []
        variablesPanelVC.setVariables(vars)
        editorVC.setVariableNames(Set(vars.map { $0.name }.filter { !$0.isEmpty }))
        variablesToggle.contentTintColor = (tab?.variablesPanelVisible ?? false)
            ? .controlAccentColor : .secondaryLabelColor
        view.needsLayout = true
    }
```

- [ ] **Step 6: Rebind on tab switch**

At the end of `tabChanged(from:to:)` (after line 355 `updateSchemaPopupTitle()`), add:

```swift
        syncVariablesPanel()
```

- [ ] **Step 7: Regenerate, build, and manually verify**

Run: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

Then run the app (Xcode ⌘R). Verify:
- The `curlybraces` button sits at the far right of the editor toolbar.
- Clicking it slides in the panel on the right of the editor; the editor narrows.
- Add a variable, type a name — the matching `{{name}}` token in the editor turns indigo; an unknown `{{other}}` shows red.
- Drag the divider — panel resizes and the width sticks after toggling off/on and after relaunch.
- Switch tabs — the panel shows that tab's variables and its own visibility.

- [ ] **Step 8: Commit**

```bash
git add Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "feat: variables panel toggle, docking, resize, and per-tab rebind"
```

---

## Phase F — Rendered editor export

### Task 11: Render on "Export as SQL File"

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift:1972-1996` (`menuExportEditorAsSQL`)

**Note:** "Export as SQL File" produces a handoff artifact, so it renders. "Save"/"Save As" preserve token form (unchanged). Result-tab Copy and history already render because `performQuery` substitutes upstream.

- [ ] **Step 1: Render the exported text**

In `menuExportEditorAsSQL`, replace line 1974:

```swift
        let text = focusedPaneVC?.getSQL() ?? ""
```

with:

```swift
        let raw = focusedPaneVC?.getSQL() ?? ""
        let text = VariableSubstitutor.render(raw, with: tab.variables).sql
```

(`tab` is already in scope from line 1973. Unresolved tokens are left verbatim — acceptable for a non-executing export.)

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: render variables when exporting editor SQL to file"
```

---

## Phase G — Saved-query persistence (Rust + Swift)

Variables are stored as a JSON string in a new `variables TEXT` column on `saved_queries`. `nil`/absent = no variables (backward compatible).

### Task 12: Rust — schema, migration, and CRUD

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs:214-224` (CREATE TABLE)
- Modify: `pharos-core/src/db/sqlite.rs` (add migration after saved_queries create)
- Modify: `pharos-core/src/db/sqlite.rs:414-442` (create)
- Modify: `pharos-core/src/db/sqlite.rs:445-463` (load)
- Modify: `pharos-core/src/db/sqlite.rs:466-486` (get)
- Modify: `pharos-core/src/db/sqlite.rs:489-533` (update)

- [ ] **Step 1: Add the column to CREATE TABLE**

In the `CREATE TABLE IF NOT EXISTS saved_queries (...)` statement, add a `variables TEXT` column before the `FOREIGN KEY` line:

```sql
        CREATE TABLE IF NOT EXISTS saved_queries (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            folder TEXT,
            sql TEXT NOT NULL,
            connection_id TEXT,
            variables TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE SET NULL
        );
```

- [ ] **Step 2: Add an idempotent ADD COLUMN migration**

Mirror the existing `color`-column migration pattern (lines 146-158). Add this after the table-creation `execute_batch` block that includes `saved_queries` (i.e. after the big init batch runs, alongside the other migration checks such as the `query_history` one at lines 285-298):

```rust
    // Migration: Add variables column to saved_queries if it doesn't exist
    let has_variables_column: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('saved_queries') WHERE name = 'variables'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_variables_column {
        conn.execute("ALTER TABLE saved_queries ADD COLUMN variables TEXT", [])?;
    }
```

- [ ] **Step 3: Update create_saved_query**

Replace the INSERT and returned struct (lines 417-441) so `variables` is written and returned:

```rust
    conn.execute(
        r#"
        INSERT INTO saved_queries (id, name, folder, sql, connection_id, variables, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        (
            id,
            &query.name,
            &query.folder,
            &query.sql,
            &query.connection_id,
            &query.variables,
            &now,
            &now,
        ),
    )?;

    Ok(SavedQuery {
        id: id.to_string(),
        name: query.name.clone(),
        folder: query.folder.clone(),
        sql: query.sql.clone(),
        connection_id: query.connection_id.clone(),
        variables: query.variables.clone(),
        created_at: now.clone(),
        updated_at: now,
    })
```

- [ ] **Step 4: Update load_saved_queries**

`variables` is appended at the END of the SELECT column list to keep indices 0-6 stable. Replace lines 447-460:

```rust
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at, variables FROM saved_queries ORDER BY name",
    )?;

    let queries = stmt.query_map([], |row| {
        Ok(SavedQuery {
            id: row.get(0)?,
            name: row.get(1)?,
            folder: row.get(2)?,
            sql: row.get(3)?,
            connection_id: row.get(4)?,
            created_at: row.get(5)?,
            updated_at: row.get(6)?,
            variables: row.get(7)?,
        })
    })?;
```

- [ ] **Step 5: Update get_saved_query**

Replace lines 467-482 the same way:

```rust
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at, variables FROM saved_queries WHERE id = ?1",
    )?;

    let mut rows = stmt.query([query_id])?;

    if let Some(row) = rows.next()? {
        Ok(Some(SavedQuery {
            id: row.get(0)?,
            name: row.get(1)?,
            folder: row.get(2)?,
            sql: row.get(3)?,
            connection_id: row.get(4)?,
            created_at: row.get(5)?,
            updated_at: row.get(6)?,
            variables: row.get(7)?,
        }))
    } else {
        Ok(None)
    }
```

- [ ] **Step 6: Update update_saved_query for the dynamic builder**

Add a `variables` param push and SQL-part. In the params section (after the `sql` push, ~line 503) add:

```rust
    if let Some(ref variables) = update.variables {
        params.push(Box::new(variables.clone()));
    }
```

And in the `sql_parts` section (after the `sql` block, ~line 519) add:

```rust
    if update.variables.is_some() {
        sql_parts.push(format!("variables = ?{}", idx));
        idx += 1;
    }
```

(The `idx += 1` keeps the trailing `WHERE id = ?{idx}` placeholder correct.)

- [ ] **Step 7: Commit (build happens after the model change in Task 13)**

```bash
git add pharos-core/src/db/sqlite.rs
git commit -m "feat(core): persist saved-query variables column + migration + CRUD"
```

---

### Task 13: Rust — add variables to the models

**Files:**
- Modify: `pharos-core/src/models/saved_query.rs:5-31`

- [ ] **Step 1: Add the field to all three structs**

Add `pub variables: Option<String>,` to `SavedQuery` (after `connection_id`), to `CreateSavedQuery` (after `connection_id`), and to `UpdateSavedQuery` (after `sql`):

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedQuery {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSavedQuery {
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSavedQuery {
    pub id: String,
    pub name: Option<String>,
    pub folder: Option<String>,
    pub sql: Option<String>,
    pub variables: Option<String>,
}
```

- [ ] **Step 2: Build the Rust core (regenerates the C header via cbindgen)**

Run: `cd pharos-core && cargo build --release`
Expected: `Finished` with no errors. (The FFI wrappers in `ffi/saved_queries.rs` pass JSON generically, so they need no change.)

- [ ] **Step 3: Commit**

```bash
git add pharos-core/src/models/saved_query.rs
git commit -m "feat(core): add variables field to SavedQuery models"
```

---

### Task 14: Swift — SavedQuery DTOs

**Files:**
- Modify: `Pharos/Models/SavedQuery.swift:3-27`

- [ ] **Step 1: Add the field to all three structs**

Add `var variables: String?` matching Rust's camelCase JSON:

```swift
struct SavedQuery: Codable, Identifiable {
    let id: String
    var name: String
    var folder: String?
    var sql: String
    var connectionId: String?
    var variables: String?
    let createdAt: String
    let updatedAt: String
}

struct CreateSavedQuery: Codable {
    let name: String
    let folder: String?
    let sql: String
    let connectionId: String?
    let variables: String?
}

struct UpdateSavedQuery: Codable {
    let id: String
    let name: String?
    let folder: String?
    let sql: String?
    let variables: String?
}
```

- [ ] **Step 2: Build to verify it compiles (will fail — call sites need updating)**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: FAIL — `CreateSavedQuery`/`UpdateSavedQuery` initializers now require `variables:` at existing call sites (SaveQuerySheet, ContentViewController). Fixed in Task 15.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/SavedQuery.swift
git commit -m "feat: add variables field to Swift SavedQuery DTOs"
```

---

### Task 15: Swift — persist & restore variables through save paths

**Files:**
- Modify: `Pharos/Sheets/SaveQuerySheet.swift` (accept + send variables)
- Modify: `Pharos/ViewControllers/ContentViewController.swift:1953` (`menuSaveQuery` update path)
- Modify: `Pharos/ViewControllers/ContentViewController.swift:1998-2013` (`presentSaveQuerySheet`)
- Modify: `Pharos/ViewControllers/ContentViewController.swift:1810-1813` (open-saved-query restore)

Variables serialize with a shared helper. Add it once (e.g. top of the SavedQuery-related extension in ContentViewController, or as a small static on `SavedQuery`). Put it in `SavedQuery.swift`:

- [ ] **Step 1: Add JSON encode/decode helpers on SavedQuery.swift**

Append to `Pharos/Models/SavedQuery.swift`:

```swift
extension Array where Element == QueryVariable {
    /// Serialize to a JSON string for saved-query storage; nil if empty.
    func toSavedJSON() -> String? {
        guard !isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SavedQueryVariables {
    /// Decode a saved-query `variables` JSON string; [] if nil/invalid.
    static func decode(_ json: String?) -> [QueryVariable] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QueryVariable].self, from: data)) ?? []
    }
}
```

- [ ] **Step 2: Thread variables into SaveQuerySheet**

In `SaveQuerySheet`, add a stored `variables` and accept it in `init`. Change the property block (lines 16-19) and `init` (lines 21-26):

```swift
    private let initialName: String
    private let sql: String
    private let variables: [QueryVariable]
    private var existingQueries: [SavedQuery] = []
    private var onSave: ((SaveQueryAction) -> Void)?

    init(tabName: String, sql: String, variables: [QueryVariable], onSave: @escaping (SaveQueryAction) -> Void) {
        self.initialName = tabName
        self.sql = sql
        self.variables = variables
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
```

Update `replaceQuery` (line 182) and `createNewQuery` (line 197) to send the JSON:

```swift
            let update = UpdateSavedQuery(id: duplicate.id, name: name, folder: folder, sql: sql, variables: variables.toSavedJSON())
```

```swift
        let create = CreateSavedQuery(name: name, folder: folder, sql: sql, connectionId: nil, variables: variables.toSavedJSON())
```

- [ ] **Step 3: Pass variables when presenting the sheet**

In `presentSaveQuerySheet(tab:)` (line 1999), add the argument:

```swift
        let sheet = SaveQuerySheet(
            tabName: tab.name,
            sql: focusedPaneVC?.getSQL() ?? "",
            variables: tab.variables
        ) { [weak self] action in
```

- [ ] **Step 4: Include variables in the in-place update (Cmd+S)**

In `menuSaveQuery`, replace line 1953:

```swift
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: currentSQL)
```

with:

```swift
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: currentSQL, variables: tab.variables.toSavedJSON())
```

- [ ] **Step 5: Restore variables when opening a saved query into a tab**

At the open-saved-query path (lines 1812-1813), add variable restoration:

```swift
        let tab = stateManager.createTab(sql: query.sql, name: query.name)
        stateManager.updateTab(id: tab.id) {
            $0.savedQueryId = query.id
            $0.variables = SavedQueryVariables.decode(query.variables)
        }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Pharos/Models/SavedQuery.swift Pharos/Sheets/SaveQuerySheet.swift Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: persist and restore query variables via saved queries"
```

---

### Task 16: Render variables on Saved-Queries copy/export

**Files:**
- Modify: `Pharos/ViewControllers/SavedQueriesVC.swift:382` (Copy SQL)
- Modify: `Pharos/ViewControllers/SavedQueriesVC.swift:400,499` (SQL file export)

- [ ] **Step 1: Render on Copy SQL**

At line 382, the pasteboard write currently uses `q.sql` / `queries[row].sql`. Read the exact expression there, then wrap the SQL string in a render call using that query's stored variables. For a `SavedQuery` value `q`:

```swift
        let sqlToCopy = VariableSubstitutor.render(q.sql, with: SavedQueryVariables.decode(q.variables)).sql
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sqlToCopy, forType: .string)
```

Apply the same pattern (`VariableSubstitutor.render(<query>.sql, with: SavedQueryVariables.decode(<query>.variables)).sql`) to the SQL-file export calls at lines 400 and 499 that pass `q.sql` / `p.sql` into `SQLFileWriter.write(...)`.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual end-to-end verification (run the app)**

Run the app (Xcode ⌘R) and verify the full flow:
1. Write `SELECT * FROM http WHERE orig_h = '{{ip}}' AND timestamp > '{{since}}';`
2. Open the panel; add `ip` = `8.8.4.4` (Text), `since` = `2026-07-01` (Text).
3. Run the query — it executes with `orig_h = '8.8.4.4' AND timestamp > '2026-07-01'` (check the result tab's Copy Query shows the rendered SQL).
4. Remove the `ip` variable and run — a red error toast names `{{ip}}` and the panel opens.
5. Set `ip` type to Number with value `abc` and run — an invalid-number toast appears.
6. Save the query, close the tab, reopen it from the sidebar — variables are restored; right-click → Copy SQL yields rendered SQL.
7. Save/Save As and "Export as SQL File": Save keeps `{{…}}` tokens in the tab; Export writes rendered SQL.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/SavedQueriesVC.swift
git commit -m "feat: render variables on saved-query copy/export"
```

---

## Verification summary

- **Unit:** `./scripts/test-variable-substitutor.sh` → `ALL PASSED`.
- **Compile:** `xcodegen generate && xcodebuild ... build` → `** BUILD SUCCEEDED **`.
- **Rust:** `cd pharos-core && cargo build --release` → `Finished`.
- **Manual E2E:** Task 16 Step 3 checklist.

## Notes / acceptable limitations

- Queries containing `{{tokens}}` skip live syntax validation (validated for real at execution).
- Undefined/invalid tokens block execution with a toast + auto-opened panel; they are left verbatim in non-executing exports.
- Undefined-token flagging uses a distinct color (`systemRed`); a dashed underline is a possible future polish.
- Panel width is app-wide (`UserDefaults`); panel visibility is per-tab.
