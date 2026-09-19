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

func runTests() {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        testToggleWrites()
        testPopulatingBlocksWrites()
        testRefreshPullsValues()
        testDependentDims()
        testUnavailableReasonReplacesCaption()
        testOutOfRangeTextIsIgnored()
        testAccessibility()
        testFooterButtonsTrailing()
    }
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
