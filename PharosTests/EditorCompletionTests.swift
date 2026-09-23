// Standalone tests for the SQL editor's completion: the `{{` variable list
// (VariableCompletion's pure rules, then the real SQLTextView +
// SQLCompletionProvider typed into), the dot rule, and the `complete:` action.
//
// Compiled with SQLCompletionProvider.swift, SQLTextView.swift and their
// dependencies by scripts/test-editor-completion.sh. The text view lives in a
// borderless window ordered in far off screen (a popover needs a window on
// screen); keys go through `keyDown(with:)` with real NSEvents, so the text
// view's own key routing is what is tested.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - VariableCompletion: context

/// `text` with `|` marking the caret.
private func context(_ marked: String) -> VariableCompletion.Context? {
    let caret = (marked as NSString).range(of: "|").location
    let text = marked.replacingOccurrences(of: "|", with: "") as NSString
    return VariableCompletion.context(in: text, caret: caret)
}

private func testContext() {
    expectEqual(context("SELECT {{|}}"),
                VariableCompletion.Context(typed: "", replaceRange: NSRange(location: 9, length: 2)),
                "context: empty token, replace covers the closing pair")
    expectEqual(context("x = {{us|}}")?.typed, "us", "context: typed name before the caret")
    expectEqual(context("x = {{us|}}")?.replaceRange, NSRange(location: 6, length: 4),
                "context: replace covers name + }}")
    expectEqual(context("{{us|er}} + 1")?.typed, "us", "context: caret mid-name filters by the part before it")
    expectEqual(context("{{us|er}} + 1")?.replaceRange, NSRange(location: 2, length: 6),
                "context: caret mid-name replaces the whole name + }}")
    expectEqual(context("{{ us| }}")?.replaceRange, NSRange(location: 3, length: 5),
                "context: spaces inside the braces are allowed and replaced")
    expectEqual(context("{{us|")?.replaceRange, NSRange(location: 2, length: 2),
                "context: no closing pair, replace covers the name only")
    expectEqual(context("'{{d|}}'")?.typed, "d", "context: inside a string literal")
    expectTrue(context("{{us |}}") == nil, "context: a space after the name ends the token")
    expectTrue(context("{{a.|}}") == nil, "context: a dot ends the token")
    expectTrue(context("{us|}") == nil, "context: one brace is not a token")
    expectTrue(context("{{us}}|") == nil, "context: after the closing pair is outside")
    expectTrue(context("{{\nus|}}") == nil, "context: a newline inside the braces is not a token")
    expectTrue(context("SELECT us|") == nil, "context: plain identifier is not a token")
}

// MARK: - VariableCompletion: items

private func names(_ items: [VariableCompletion.Item]) -> [String] {
    items.map { $0.isNew ? "+\($0.name)" : $0.name }
}

private func testItems() {
    let vars = ["start_date", "user_id", "id_list", "user", "", "user_id"]
    expectEqual(names(VariableCompletion.items(names: vars, typed: "")),
                ["start_date", "user_id", "id_list", "user"],
                "items: nothing typed lists every name once, no new row")
    expectEqual(names(VariableCompletion.items(names: vars, typed: "user")),
                ["user", "user_id"],
                "items: exact match first, then prefix; no new row when the name exists")
    expectEqual(names(VariableCompletion.items(names: vars, typed: "id")),
                ["id_list", "user_id", "+id"],
                "items: prefix before contains; new row last")
    expectEqual(names(VariableCompletion.items(names: vars, typed: "ID")),
                ["id_list", "user_id", "+ID"],
                "items: filtering ignores case, the exact match does not")
    expectEqual(names(VariableCompletion.items(names: vars, typed: "zone")),
                ["+zone"],
                "items: an unknown name is the only row, so Tab creates it")
    expectEqual(names(VariableCompletion.items(names: vars, typed: "123")),
                [],
                "items: an all-digit name gets no new row (it cannot resolve)")
    expectEqual(names(VariableCompletion.items(names: [], typed: "_x1")),
                ["+_x1"],
                "items: underscore and digits are a valid new name")
}

// MARK: - VariableCompletion: brace pairing

private func at(_ marked: String) -> (NSString, Int) {
    let caret = (marked as NSString).range(of: "|").location
    return (marked.replacingOccurrences(of: "|", with: "") as NSString, caret)
}

private func testBracePairing() {
    func autoClose(_ m: String) -> Bool { let (t, c) = at(m); return VariableCompletion.shouldAutoClose(in: t, at: c) }
    func stepOver(_ m: String) -> Bool { let (t, c) = at(m); return VariableCompletion.shouldStepOver(in: t, at: c) }
    func emptyPair(_ m: String) -> NSRange? { let (t, c) = at(m); return VariableCompletion.emptyPairRange(in: t, at: c) }

    expectTrue(autoClose("SELECT {|"), "autoClose: second brace at the end")
    expectTrue(autoClose("x = {| AND"), "autoClose: before a space")
    expectTrue(autoClose("'{|'"), "autoClose: before a closing quote")
    expectTrue(autoClose("f({|)"), "autoClose: before )")
    expectTrue(!autoClose("x = |"), "autoClose: first brace alone does not")
    expectTrue(!autoClose("{{|"), "autoClose: not a third brace")
    expectTrue(!autoClose("{|abc"), "autoClose: not with text after the caret")
    expectTrue(!autoClose("{|}}"), "autoClose: not before an existing }}")

    expectTrue(stepOver("{{name|}}"), "stepOver: first } before the pair")
    expectTrue(stepOver("{{name}|}"), "stepOver: second } of the pair")
    expectTrue(stepOver("{{|}}"), "stepOver: empty token")
    expectTrue(!stepOver("{{name}}|}"), "stepOver: not a stray } after the token")
    expectTrue(!stepOver("x = {a|}"), "stepOver: not a single-brace pair")
    expectTrue(!stepOver("{{name|"), "stepOver: nothing to step over")

    expectEqual(emptyPair("x {{|}} y"), NSRange(location: 2, length: 4), "emptyPair: {{|}} goes whole")
    expectTrue(emptyPair("{{a|}}") == nil, "emptyPair: not with a name")
    expectTrue(emptyPair("{{|}") == nil, "emptyPair: not a half pair")
}

// MARK: - Dot rule (bug A)

private func dotContext(_ marked: String) -> SQLCompletionProvider.CompletionContext? {
    let (text, caret) = at(marked)
    var wordStart = caret
    while wordStart > 0, let s = UnicodeScalar(text.character(at: wordStart - 1)),
          CharacterSet.alphanumerics.contains(s) || s == "_" {
        wordStart -= 1
    }
    return SQLCompletionProvider.analyzeContext(text: text, cursor: caret, wordStart: wordStart)
}

private func testDotRule() {
    expectEqual(dotContext("SELECT * FROM public.|"), .afterDot(qualifier: "public"), "dot: schema.")
    expectEqual(dotContext("SELECT users.na|"), .afterDot(qualifier: "users"), "dot: table.partial")
    expectEqual(dotContext("SELECT \"My Table\".|"), .afterDot(qualifier: "My Table"), "dot: \"quoted\".")
    expectTrue(dotContext("SELECT .|") == nil, "dot: nothing before the dot → no list")
    expectTrue(dotContext("SELECT (a).|") == nil, "dot: a bracket before the dot → no list")
    expectTrue(dotContext("SELECT 1.|") == nil, "dot: a number before the dot → no list")
    expectEqual(dotContext("SELECT * FROM |"), .afterFrom, "dot: keyword contexts are unchanged")
    expectEqual(dotContext("SEL|"), .general, "dot: general context unchanged")
}

// MARK: - Typed into the real editor

/// Mirrors QueryEditorVC's delegate extension, and counts triggers.
private final class Host: SQLTextViewCompletionDelegate {
    let provider = SQLCompletionProvider()
    var triggers = 0
    var isCompletionShown: Bool { provider.isShown }
    func triggerCompletion() { triggers += 1; provider.showCompletions(for: textView) }
    func updateCompletion() { provider.showCompletions(for: textView) }
    func dismissCompletion() { provider.dismiss() }
    func completionMoveUp() -> Bool { guard provider.isShown else { return false }; provider.moveUp(); return true }
    func completionMoveDown() -> Bool { guard provider.isShown else { return false }; provider.moveDown(); return true }
    func acceptCompletion() -> Bool { guard provider.isShown else { return false }; provider.acceptSelected(); return true }
    unowned var textView: SQLTextView
    init(textView: SQLTextView) { self.textView = textView }
}

private final class Editor {
    let window: NSWindow
    let textView: SQLTextView
    let host: Host
    var chosen: [String] = []

    init(variables: [String] = ["start_date", "user_id", "user"]) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        textView = SQLTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = textView
        // An NSPopover only shows from a view in a window that is on screen.
        // Far off every display, so nothing appears on the user's screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeFirstResponder(textView)
        host = Host(textView: textView)
        host.provider.attachTo(textView)
        host.provider.variables = variables.map { .init(name: $0, preview: "v") }
        textView.completionDelegate = host
        host.provider.onVariableChosen = { [unowned self] in self.chosen.append($0) }
    }

    func type(_ s: String) {
        for ch in s { textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    func key(_ code: UInt16, _ chars: String) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        textView.keyDown(with: event)
    }
    func tab() { key(48, "\t") }
    func down() { key(125, String(UnicodeScalar(0xF701)!)) }
    func escape() { key(53, "\u{1b}") }
    func backspace() { textView.deleteBackward(nil) }

    var text: String { textView.string }
    var caret: Int { textView.selectedRange().location }
    var shown: Bool { host.provider.isShown }
}

private func testTypedIntoEditor() {
    // `{{` pairs, opens the list at once, Tab takes the top row.
    do {
        let e = Editor()
        e.type("SELECT {{")
        expectEqual(e.text, "SELECT {{}}", "editor: {{ gets }}")
        expectEqual(e.caret, 9, "editor: the caret sits between the braces")
        expectTrue(e.shown, "editor: the variable list opens on {{ with no debounce")
        e.type("us")
        expectTrue(e.shown, "editor: typing a name keeps the list open")
        e.tab()
        expectEqual(e.text, "SELECT {{user_id}}", "editor: Tab writes the top row (prefix match, list order)")
        expectEqual(e.caret, 18, "editor: the caret lands after }}")
        expectTrue(!e.shown, "editor: the list closes on accept")
        expectEqual(e.chosen, ["user_id"], "editor: accept reports the chosen name")
    }
    // Down moves the selection.
    do {
        let e = Editor()
        e.type("{{us")
        e.down()
        e.tab()
        expectEqual(e.text, "{{user}}", "editor: Down + Tab takes the second row")
        expectEqual(e.chosen, ["user"], "editor: the second row's name is reported")
    }
    // Unknown name: Tab creates it.
    do {
        let e = Editor()
        e.type("WHERE d = '{{zone")
        expectEqual(e.text, "WHERE d = '{{zone}}'", "editor: pairs inside a string literal")
        expectTrue(e.shown, "editor: an unknown name shows the new-variable row")
        e.tab()
        expectEqual(e.text, "WHERE d = '{{zone}}'", "editor: Tab keeps the text for a new name")
        expectEqual(e.caret, 19, "editor: caret after }} for a new name")
        expectEqual(e.chosen, ["zone"], "editor: the new name is reported")
    }
    // `}` steps over, and closes the list without choosing.
    do {
        let e = Editor()
        e.type("{{user}}")
        expectEqual(e.text, "{{user}}", "editor: typing }} steps over the pair")
        expectEqual(e.caret, 8, "editor: caret after the stepped-over pair")
        expectTrue(!e.shown, "editor: stepping out closes the list")
        expectEqual(e.chosen, [], "editor: stepping out chooses nothing")
    }
    // Backspace on the empty pair; a space closes the list.
    do {
        let e = Editor()
        e.type("a {{")
        e.backspace()
        expectEqual(e.text, "a ", "editor: Backspace removes an empty {{}} whole")
        expectTrue(!e.shown, "editor: the list closes with the pair")
        e.type("{{user ")
        expectTrue(!e.shown, "editor: a space after the name closes the list")
        expectEqual(e.chosen, [], "editor: closing chooses nothing")
    }
    // Escape closes; nothing chosen. (A second Escape would open it again.)
    do {
        let e = Editor()
        e.type("{{st")
        expectTrue(e.shown, "editor: list open before Escape")
        e.escape()
        expectTrue(!e.shown, "editor: Escape closes the list")
        e.tab()
        expectEqual(e.text, "{{st  }}", "editor: Tab after Escape indents as usual")
        expectEqual(e.chosen, [], "editor: Escape chooses nothing")
    }
    // Settings.
    do {
        let e = Editor()
        e.textView.completionTrigger = .off
        e.type("{{us")
        expectTrue(!e.shown, "editor: trigger Off → no automatic list")
        expectEqual(e.text, "{{us}}", "editor: trigger Off still pairs")
    }
    do {
        let e = Editor()
        e.textView.autoPairBrackets = false
        e.type("{{us")
        expectEqual(e.text, "{{us", "editor: auto-pair off → no }}")
        expectTrue(e.shown, "editor: auto-pair off still opens the list")
        e.tab()
        expectEqual(e.text, "{{user_id}}", "editor: accept writes }} when it was not there")
    }
    // The SQL list never opens inside a token, even with nothing to offer.
    do {
        let e = Editor(variables: [])
        e.textView.completionTrigger = .afterDotAndIdentifiers
        e.type("SELECT {{")
        expectTrue(!e.shown, "editor: no variables and nothing typed → no list")
        e.type("123")
        expectTrue(!e.shown, "editor: all-digit name in a token → no list (and no SQL list)")
    }
    // Bug A: a bare dot opens nothing.
    do {
        let e = Editor()
        e.type("SELECT .")
        expectTrue(!e.shown, "editor: SELECT . opens no list")
    }
    // Bug A: schema lookup ignores case.
    do {
        let e = Editor()
        e.host.provider.tables = ["Sales": [TableInfo(name: "orders", schemaName: "Sales", tableType: .table,
                                                      rowCountEstimate: nil, totalSizeBytes: nil)]]
        e.type("SELECT * FROM sales.")
        expectTrue(e.shown, "editor: sales. lists the tables of schema Sales")
        e.tab()
        expectEqual(e.text, "SELECT * FROM sales.orders", "editor: the member goes after the dot")
    }
    // Bug B: `complete:` (Esc, ⌥Esc, F5) opens our list.
    do {
        let e = Editor()
        e.type("{{st")
        e.escape()
        let before = e.host.triggers
        e.textView.complete(nil)
        expectEqual(e.host.triggers, before + 1, "complete: triggers our completion")
        expectTrue(e.shown, "complete: shows the list")
        e.escape()
        expectTrue(!e.shown, "Escape closes the open list")
        e.escape()
        expectTrue(e.shown, "Escape with no list open opens it")
        e.escape()
        // ⌥Esc goes through the key bindings to `complete:`.
        e.textView.interpretKeyEvents([NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: e.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!])
        expectTrue(e.shown, "Option-Escape reaches complete: and opens the list")
    }
}

func runTests() {
    _ = NSApplication.shared
    testContext()
    testItems()
    testBracePairing()
    testDotRule()
    testTypedIntoEditor()
    if failures == 0 { print("\nAll editor completion tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
