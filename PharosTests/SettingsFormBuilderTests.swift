// Standalone test runner for SettingsFormBuilder — the declarative layer of
// the Settings window. Compiled with the Furniture kit by
// scripts/test-settings-form-builder.sh. No FFI: bindings here are closures
// over local variables, standing in for `SettingsBinding.settings(_:)`.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

/// A store the bindings read and write, like the settings store does.
private final class Store {
    var appleIntelligence = true
    var describeQuery = true
    var rowLimit = 1000
    var name = "Pharos"
    var address = ""
    var model = ""
    var modelOptions: [String] = []
    var reloads = 0
    var systemModelAvailable = true
}

@MainActor
private func makeForm(store: Store, populating: @escaping () -> Bool = { false })
    -> (builder: SettingsFormBuilder, view: NSView, window: NSWindow) {
    let builder = SettingsFormBuilder()
    builder.isPopulating = populating
    let sections = [
        SettingsSection(title: "Apple Intelligence", items: [
            SettingsItem(id: "appleIntelligence", title: "Use Apple Intelligence features",
                         caption: "Nothing leaves this Mac.", icon: "sparkles",
                         kind: .toggle(SettingsBinding(get: { store.appleIntelligence }, set: { store.appleIntelligence = $0 })),
                         availability: { store.systemModelAvailable ? .available : .unavailable(reason: "Apple Intelligence is not available on this Mac right now.") }),
            SettingsItem(id: "describeQuery", title: "Describe the query",
                         kind: .toggle(SettingsBinding(get: { store.describeQuery }, set: { store.describeQuery = $0 })),
                         dependsOn: "appleIntelligence"),
        ]),
        SettingsSection(title: "Rows", items: [
            SettingsItem(id: "rowLimit", title: "Row limit",
                         kind: .stepper(SettingsBinding(get: { store.rowLimit }, set: { store.rowLimit = $0 }), range: 1...100_000, unit: "rows")),
            SettingsItem(id: "name", title: "Application name",
                         kind: .text(SettingsBinding(get: { store.name }, set: { store.name = $0 }), width: 200)),
            SettingsItem(id: "address", title: "Endpoint address",
                         caption: "The API root of an OpenAI-compatible endpoint, such as https://api.example.com/v1 or http://localhost:11434/v1.",
                         icon: "network", help: "Longer help.",
                         kind: .text(SettingsBinding(get: { store.address }, set: { store.address = $0 }), width: 0,
                                     placeholder: "https://api.example.com/v1", below: true)),
            SettingsItem(id: "model", title: "Model name",
                         kind: .combo(SettingsBinding(get: { store.model }, set: { store.model = $0 }), width: 200,
                                      options: { store.modelOptions },
                                      reload: (title: "List the models", handler: { store.reloads += 1 }))),
        ], footerButtons: [
            SettingsFooterButton(id: "clear", title: "Clear…", destructive: true) { store.rowLimit = 0 },
            SettingsFooterButton(id: "more", title: "More") {},
        ]),
    ]
    let content = builder.build(sections, paneId: "general")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSView(frame: window.contentView!.bounds)
    window.contentView = host
    content.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        content.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
    builder.refreshAll()
    host.layoutSubtreeIfNeeded()
    return (builder, content, window)
}

@MainActor
private func testToggleWrites() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    let toggle = builder.control(for: "appleIntelligence") as? NSSwitch
    expectTrue(toggle != nil, "the toggle item makes an NSSwitch")
    expectEqual(toggle?.state, .on, "refreshAll pulled the stored true into the switch")
    toggle?.performClick(nil)
    expectEqual(store.appleIntelligence, false, "a toggle click writes the binding")
    toggle?.performClick(nil)
    expectEqual(store.appleIntelligence, true, "and writes it back")
}

@MainActor
private func testPopulatingBlocksWrites() {
    let store = Store()
    var populating = true
    let (builder, _, _) = makeForm(store: store, populating: { populating })
    let toggle = builder.control(for: "appleIntelligence") as! NSSwitch
    toggle.performClick(nil)
    expectEqual(store.appleIntelligence, true, "isPopulating blocks the write")
    populating = false
    toggle.performClick(nil)
    expectEqual(store.appleIntelligence, toggle.state == .on, "the write goes through once populating ends")
}

@MainActor
private func testRefreshPullsValues() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    store.rowLimit = 250
    store.name = "Renamed"
    builder.refreshAll()
    let container = builder.control(for: "rowLimit")
    let field = container?.subviews.compactMap { $0 as? NSTextField }.first
    let stepper = container?.subviews.compactMap { $0 as? NSStepper }.first
    expectEqual(field?.integerValue, 250, "refreshAll pulls the number into the field")
    expectEqual(stepper?.integerValue, 250, "…and into the stepper")
    expectEqual((builder.control(for: "name") as? NSTextField)?.stringValue, "Renamed", "…and the text")
}

@MainActor
private func testDependentDims() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    let parent = builder.control(for: "appleIntelligence") as! NSSwitch
    let child = builder.row(for: "describeQuery")!
    expectEqual(child.isEnabled, true, "dependent row is enabled while its parent is on")
    expectTrue(child.titleLabel.frame.minX > builder.row(for: "appleIntelligence")!.titleLabel.frame.minX - 1,
               "dependent row is laid out (indent applies)")
    parent.performClick(nil)
    expectEqual(child.isEnabled, false, "dependent row dims when the parent is switched off")
    expectEqual((child.control as? NSSwitch)?.isEnabled, false, "…and its control is disabled")
    parent.performClick(nil)
    expectEqual(child.isEnabled, true, "dependent row undims when the parent comes back")
}

@MainActor
private func testUnavailableReasonReplacesCaption() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    let row = builder.row(for: "appleIntelligence")!
    expectEqual(row.captionLabel.stringValue, "Nothing leaves this Mac.", "available: the caption is the item's caption")
    store.systemModelAvailable = false
    builder.refreshAll()
    expectEqual(row.captionLabel.stringValue, "Apple Intelligence is not available on this Mac right now.",
                "unavailable: the reason replaces the caption")
    expectEqual(row.isEnabled, false, "unavailable: the row is disabled")
    expectEqual((row.control as? NSSwitch)?.isEnabled, false, "unavailable: the control is disabled")
    store.systemModelAvailable = true
    builder.refreshAll()
    expectEqual(row.isEnabled, true, "available again: the row is enabled")
    expectEqual(row.captionLabel.stringValue, "Nothing leaves this Mac.", "available again: the caption is back")
}

@MainActor
private func testOutOfRangeTextIsIgnored() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    let container = builder.control(for: "rowLimit")!
    let field = container.subviews.compactMap { $0 as? NSTextField }.first!
    field.stringValue = "0"
    builder.commit(field)
    expectEqual(store.rowLimit, 1000, "an out-of-range commit leaves the binding unchanged")
    field.stringValue = "500000"
    builder.commit(field)
    expectEqual(store.rowLimit, 1000, "…above the range too")
    field.stringValue = "abc"
    builder.commit(field)
    expectEqual(store.rowLimit, 1000, "…and a non-number")
    field.stringValue = "42"
    builder.commit(field)
    expectEqual(store.rowLimit, 42, "an in-range commit writes")
    let stepper = container.subviews.compactMap { $0 as? NSStepper }.first!
    expectEqual(stepper.integerValue, 42, "the stepper follows a typed value")
    // `NSStepper` is not a button: `performClick` does not fire its action
    // offscreen, so the test sends the action the way a real click does.
    stepper.integerValue = 43
    _ = stepper.sendAction(stepper.action, to: stepper.target)
    expectEqual(store.rowLimit, 43, "a stepper click writes")
    expectEqual(field.integerValue, 43, "the field follows the stepper")
}

@MainActor
private func testCommitKeepsTextBeingTyped() {
    // A number is out of range on its way to being in range. The debounced
    // commit must not disturb the field editor while it is.
    let store = Store()
    let (builder, _, window) = makeForm(store: store)
    let container = builder.control(for: "rowLimit")!
    let field = container.subviews.compactMap { $0 as? NSTextField }.first!
    expectTrue(window.makeFirstResponder(field), "the number field takes focus")
    guard let editor = field.currentEditor() else {
        expectTrue(false, "the number field has a field editor")
        return
    }
    editor.string = "0"
    builder.commit(field)
    expectEqual(editor.string, "0", "an out-of-range commit leaves the typed text in the field")
    expectEqual(store.rowLimit, 1000, "…and writes nothing")
    editor.string = "999999"
    builder.commit(field)
    expectEqual(editor.string, "999999", "…above the range too")
    editor.string = "42"
    builder.commit(field)
    expectEqual(editor.string, "42", "an in-range commit leaves the text too")
    expectEqual(store.rowLimit, 42, "…and writes the typed value")
    window.makeFirstResponder(nil)
}

@MainActor
private func testOutOfRangeTextWarns() {
    let store = Store()
    let (builder, _, window) = makeForm(store: store)
    let row = builder.row(for: "rowLimit")!
    let container = builder.control(for: "rowLimit")!
    let field = container.subviews.compactMap { $0 as? NSTextField }.first!
    let warning = ["Enter a number from \(1.formatted()) to \(100_000.formatted())."]
    expectTrue(window.makeFirstResponder(field), "the number field takes focus for the warning")
    guard let editor = field.currentEditor() else {
        expectTrue(false, "the number field has a field editor")
        return
    }
    let type: (String) -> Void = { text in
        editor.string = text
        builder.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    expectEqual(row.captionProblems, [], "no warning before anything is typed")
    type("0")
    expectEqual(row.captionProblems, warning, "below the range warns, naming the range")
    expectEqual(editor.string, "0", "…and leaves the typed text alone")
    type("42")
    expectEqual(row.captionProblems, [], "typing into the range clears the warning")
    type("999999")
    expectEqual(row.captionProblems, warning, "above the range warns")
    type("12x")
    expectEqual(row.captionProblems, warning, "a non-number warns")
    type("")
    expectEqual(row.captionProblems, [], "an empty field does not warn")
    type("0")
    window.makeFirstResponder(nil)
    expectEqual(row.captionProblems, [], "leaving the field clears the warning…")
    expectEqual(field.integerValue, 1000, "…as the stored value is put back")
    expectEqual(store.rowLimit, 1000, "…and nothing out of range was written")
}

@MainActor
private func testAccessibility() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    let control = builder.control(for: "appleIntelligence")!
    let row = builder.row(for: "appleIntelligence")!
    expectEqual(control.accessibilityIdentifier(), "settings.general.appleIntelligence", "control identifier is settings.<pane>.<item>")
    expectTrue((control.accessibilityTitleUIElement() as? NSView) === row.titleLabel, "accessibilityTitleUIElement is the row's title label")
    expectEqual(control.accessibilityHelp(), "Nothing leaves this Mac.", "accessibilityHelp is the caption")
}

@MainActor
private func testFooterButtonsTrailing() {
    let store = Store()
    let (builder, view, _) = makeForm(store: store)
    view.layoutSubtreeIfNeeded()
    let buttons = view.descendants(of: NSButton.self).filter { $0.title == "Clear…" || $0.title == "More" }
    expectEqual(buttons.count, 2, "both footer buttons exist")
    if let last = buttons.first(where: { $0.title == "More" }), let first = buttons.first(where: { $0.title == "Clear…" }) {
        let lastRight = last.convert(last.bounds, to: view).maxX
        let firstLeft = first.convert(first.bounds, to: view).minX
        expectTrue(abs(lastRight - view.bounds.width) < 1, "footer buttons end at the trailing edge (maxX \(lastRight) of \(view.bounds.width))")
        expectTrue(firstLeft > view.bounds.width / 2, "footer buttons sit in the trailing half (minX \(firstLeft))")
        expectEqual(first.accessibilityIdentifier(), "settings.general.clear", "footer button identifier")
        expectEqual(first.hasDestructiveAction, true, "destructive footer button is marked destructive")
        first.performClick(nil)
        expectEqual(store.rowLimit, 0, "footer button handler runs")
    }
    _ = builder
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}

@MainActor
private func testDisplayRowKeepsItsInfoButton() {
    // The builder used to attach the info button only when the row had a
    // control, so `help:` on a display row was silently dropped — and a
    // display row, which reports rather than asks, is the kind most likely to
    // need the long version of its caption.
    let builder = SettingsFormBuilder()
    _ = builder.buildSectionViews([
        SettingsSection(title: "S", items: [
            SettingsItem(id: "count", title: "Stored queries",
                         caption: "How many are kept.",
                         help: "The long version.", kind: .display),
        ]),
    ], paneId: "library")
    guard let row = builder.row(for: "count") else {
        failures += 1
        print("FAIL the display row was built")
        return
    }
    let info = row.control as? SettingsInfoButton
    expectTrue(info != nil, "a display row with help gets an info button in its slot")
    expectEqual(info?.help, "The long version.", "…carrying the help text")
}

/// A text field placed below takes the row's width and leaves the caption
/// the whole text column. In the trailing slot a field wide enough for an
/// address left the caption a column three words wide.
@MainActor
private func testTextFieldBelowSpansTheRow() {
    let store = Store()
    let (builder, _, _) = makeForm(store: store)
    guard let row = builder.row(for: "address"), let field = builder.control(for: "address") as? NSTextField,
          let trailing = builder.row(for: "name"), let trailingField = builder.control(for: "name") as? NSTextField else {
        expectTrue(false, "the address row and its field exist")
        return
    }
    let fieldFrame = field.convert(field.bounds, to: row)
    let captionFrame = row.captionLabel.convert(row.captionLabel.bounds, to: row)
    expectTrue(row.isFlipped ? fieldFrame.minY >= captionFrame.maxY : fieldFrame.maxY <= captionFrame.minY,
               "the field sits under the caption (field \(fieldFrame), caption \(captionFrame))")
    expectTrue(fieldFrame.width > row.bounds.width * 0.7,
               "the field spans the row: \(fieldFrame.width) of \(row.bounds.width)")
    expectTrue(fieldFrame.maxX <= row.bounds.width, "and stays inside it")
    expectTrue(captionFrame.width > row.bounds.width * 0.6,
               "the caption has the text column to itself: \(captionFrame.width) of \(row.bounds.width)")
    expectTrue(captionFrame.height < 50, "so it wraps to a line or two, not a column: \(captionFrame.height)")
    expectEqual(field.placeholderString, "https://api.example.com/v1", "the placeholder is kept")

    let trailingFrame = trailingField.convert(trailingField.bounds, to: trailing)
    expectEqual(trailingFrame.width, 200, "a trailing field keeps its fixed width")
    expectTrue(trailingFrame.maxX > trailing.bounds.width - 60, "and its trailing place")

    // A long value does not push the row wider than the pane.
    store.address = "https://" + String(repeating: "very-long-host-name.", count: 20) + "example.com/v1"
    builder.refreshAll()
    row.window?.contentView?.layoutSubtreeIfNeeded()
    expectTrue(field.convert(field.bounds, to: row).maxX <= row.bounds.width, "a long address stays inside the row")
    expectTrue(row.bounds.width <= 560, "and the row stays inside the pane: \(row.bounds.width)")

    // Typing still commits through the builder.
    field.stringValue = "http://localhost:11434/v1"
    builder.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    expectEqual(store.address, "http://localhost:11434/v1", "a field placed below still writes its binding")
}

/// A combo row: free text, plus a list that can arrive after the pane was
/// built and a button that asks for it.
@MainActor
private func testComboOffersAListThatArrivesLater() {
    let store = Store()
    let (builder, _, window) = makeForm(store: store)
    guard let group = builder.control(for: "model"),
          let combo = group.subviews.compactMap({ $0 as? NSComboBox }).first,
          let button = group.subviews.compactMap({ $0 as? NSButton }).first(where: { !($0 is NSComboBox) }) else {
        expectTrue(false, "the model row has a combo box and a button")
        return
    }
    expectEqual(combo.numberOfItems, 0, "no list yet: a plain field")
    expectEqual(combo.accessibilityIdentifier(), "settings.general.model", "the field carries the row's identifier")
    expectEqual(button.accessibilityIdentifier(), "settings.general.model.reload", "the button has its own")
    expectEqual(button.accessibilityLabel(), "List the models", "and says what it does")

    button.performClick(nil)
    expectEqual(store.reloads, 1, "the button asks for the list")
    expectEqual(store.model, "", "and writes nothing")

    store.modelOptions = ["alpha", "beta", "gamma"]
    builder.refreshAll()
    expectEqual(combo.objectValues as? [String] ?? [], ["alpha", "beta", "gamma"], "a list that arrives later is offered")

    // Picking from the list: AppKit sets the text and sends the action.
    combo.selectItem(at: 1)
    combo.stringValue = "beta"
    builder.controlChanged(combo)
    expectEqual(store.model, "beta", "picking an item writes it at once")

    // Anything may still be typed.
    combo.stringValue = "not-on-the-list"
    builder.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: combo))
    expectEqual(store.model, "not-on-the-list", "a name that is not listed is kept as typed")

    // The list changes under a field that is being edited; the typed text stays.
    window.makeFirstResponder(combo)
    combo.currentEditor()?.string = "typing"
    store.modelOptions = ["delta"]
    builder.refreshAll()
    expectEqual(combo.objectValues as? [String] ?? [], ["delta"], "the list is replaced even while the field is being edited")
    expectEqual(combo.currentEditor()?.string ?? combo.stringValue, "typing", "and what is being typed is not overwritten")
    window.makeFirstResponder(nil)

    store.modelOptions = []
    store.model = "stored"
    builder.refreshAll()
    expectEqual(combo.numberOfItems, 0, "a list that goes away leaves a plain field")
    expectEqual(combo.stringValue, "stored", "showing the stored value")

    builder.isPopulating = { true }
    combo.stringValue = "ignored"
    builder.controlChanged(combo)
    expectEqual(store.model, "stored", "isPopulating blocks a pick too")
    builder.isPopulating = { false }
}

func runTests() {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        testToggleWrites()
        testPopulatingBlocksWrites()
        testRefreshPullsValues()
        testDependentDims()
        testUnavailableReasonReplacesCaption()
        testOutOfRangeTextIsIgnored()
        testCommitKeepsTextBeingTyped()
        testOutOfRangeTextWarns()
        testAccessibility()
        testFooterButtonsTrailing()
        testDisplayRowKeepsItsInfoButton()
        testTextFieldBelowSpansTheRow()
        testComboOffersAListThatArrivesLater()
    }
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
