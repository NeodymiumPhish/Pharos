// Standalone tests for the sidebar's navigator selector, its bottom filter
// bar, and the state behind both — compiled by
// scripts/test-sidebar-navigator.sh.
//
// What this suite is FOR. Three things here can fail silently:
//
// 1. The navigator group is built the wrong way. `selectionMode` is documented
//    as applying ONLY to a group made with one of the convenience
//    constructors; built with `init(itemIdentifier:)` plus hand-assigned
//    subitems it compiles, runs, and simply never lights a segment.
// 2. A segment loses its title. The toolbar is `.iconOnly` and
//    `NSToolbarItem` has no accessibility identifier, so the label IS what AX
//    and the tooltip read — an empty one is invisible to a compiler and to a
//    sighted tester.
// 3. A filter follows the user across a navigator switch. The schema tree and
//    the query history match on different text, so a carried-over filter
//    reads as an empty list rather than as a mistake.
//
// What it CANNOT cover: a group that is not installed in a live toolbar has no
// control representation, so `selectedIndex`, the lit/unlit state and the
// press-the-lit-one-to-collapse gesture are not observable here. Those are
// checked live with scripts/ax-do.swift.
import AppKit

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectFalse(_ condition: Bool, _ name: String) {
    if !condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name) — expected false") }
}

// MARK: - Host

/// An offscreen window is not optional here: `performClick` needs the button
/// in a window to send its action.
private func host(_ view: NSView, width: CGFloat = 260) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
    window.contentView = content
    view.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        view.topAnchor.constraint(equalTo: content.topAnchor),
    ])
    content.layoutSubtreeIfNeeded()
    return window
}

// MARK: - Cases

private func testNavigatorModel() {
    expect(Navigator.library.rawValue, 0, "library is raw value 0")
    expect(Navigator.history.rawValue, 1, "history is raw value 1")
    expect(Navigator.schema.rawValue, 2, "schema is raw value 2")
    expect(Navigator.allCases.count, 3, "three navigators")

    expect(Navigator.library.title, "Query Library", "library title")
    expect(Navigator.history.title, "Results History", "history title")
    expect(Navigator.schema.title, "Database Navigation", "schema title")

    expect(Navigator.library.symbolName, "folder", "library symbol")
    expect(Navigator.history.symbolName, "clock.arrow.circlepath", "history symbol")
    expect(Navigator.schema.symbolName, "cylinder.split.1x2", "schema symbol")
}

private func testNavigatorToolbarGroup() {
    var pressed = 0
    final class Sink: NSObject {
        var onPress: () -> Void = {}
        @objc func pressed(_ sender: Any?) { onPress() }
    }
    let sink = Sink()
    sink.onPress = { pressed += 1 }

    let group = NavigatorToolbarGroup.make(target: sink, action: #selector(Sink.pressed(_:)))

    expect(group.itemIdentifier.rawValue, "PharosNavigator", "group identifier")
    expect(NavigatorToolbarGroup.identifier.rawValue, "PharosNavigator", "identifier constant")

    // The convenience constructor is the whole point: `selectionMode` is
    // documented to apply only to a group built by one, and it creates the
    // subitems itself. Three of them, in Navigator order.
    expect(Int(group.selectionMode.rawValue),
           Int(NSToolbarItemGroup.SelectionMode.selectOne.rawValue),
           "group selects exactly one")
    expect(group.subitems.count, 3, "three subitems")

    for (index, navigator) in Navigator.allCases.enumerated() where index < group.subitems.count {
        let subitem = group.subitems[index]
        expect(subitem.label, navigator.title, "subitem \(index) label is the title")
        expect(subitem.toolTip ?? "nil", navigator.title, "subitem \(index) tooltip is the title")
        expectTrue(subitem.image != nil, "subitem \(index) has an image")
    }

    // Blank here means a blank row in Customize Toolbar…
    expect(group.label, "Navigators", "group label")
    expect(group.paletteLabel, "Navigators", "group palette label")

    // Measured live: with `.automatic` the toolbar judges the sidebar region
    // too tight and falls back to `.collapsed`, which is a pull-down menu
    // reading "Query Library" — not a capsule. `.expanded` is what makes it a
    // capsule, and the sidebar's minimumThickness (240) is sized to hold it.
    expect(Int(group.controlRepresentation.rawValue),
           Int(NSToolbarItemGroup.ControlRepresentation.expanded.rawValue),
           "group representation is expanded")

    // -1 is what the group reports when nothing is selected, and it is how the
    // toolbar draws an unlit capsule over a collapsed sidebar.
    expectTrue(NavigatorToolbarGroup.navigator(forSelectedIndex: -1) == nil,
               "-1 names no navigator")
    expectTrue(NavigatorToolbarGroup.navigator(forSelectedIndex: 1) == .history,
               "index 1 names history")
    expectTrue(NavigatorToolbarGroup.navigator(forSelectedIndex: 3) == nil,
               "an out-of-range index names no navigator")

    // The action reaches the target; the group is the sender.
    group.target = sink
    group.action = #selector(Sink.pressed(_:))
    _ = group.target
    expect(pressed, 0, "the group does not fire on construction")
}

private func testFilterBar() {
    let bar = SidebarFilterBar()
    let window = host(bar)
    defer { window.close() }

    expect(SidebarFilterBar.height, 28, "bar height constant is 28")
    expect(bar.alignmentRect(forFrame: bar.frame).height, 28, "bar lays out 28 tall")

    // Filter field: the funnel glyph, the placeholder, and a cancel button
    // that swapping the whole cell would have lost.
    expect(bar.filterField.placeholderString ?? "nil", "Filter", "placeholder is Filter")
    expectTrue(bar.filterField.sendsSearchStringImmediately, "field sends immediately")
    expectFalse(bar.filterField.sendsWholeSearchString, "field does not wait for Return")
    expect(bar.filterField.accessibilityIdentifier(), "sidebar.filter.field", "field identifier")
    let cell = bar.filterField.cell as? NSSearchFieldCell
    expectTrue(cell?.searchButtonCell?.image != nil, "search button carries an image")
    expect(cell?.searchButtonCell?.image?.accessibilityDescription ?? "nil", "Filter",
           "the glyph is described as Filter")
    expectTrue(cell?.cancelButtonCell != nil, "the cancel button survives the glyph swap")
    // The sidebar pane's minimum width comes from its fitting width, so the
    // field must be willing to shrink.
    expectTrue(bar.filterField.contentCompressionResistancePriority(for: .horizontal)
               <= NSLayoutConstraint.Priority.defaultLow,
               "the field yields horizontally")
    expectTrue(bar.fittingSize.width < 200, "the bar's fitting width stays small")

    // Add pull-down.
    expect(bar.addButton.accessibilityIdentifier(), "sidebar.filter.add", "add button identifier")
    expect(bar.addButton.accessibilityLabel() ?? "nil", "Add", "add button AX label")
    expect(Int(bar.addButton.bezelStyle.rawValue), Int(NSButton.BezelStyle.accessoryBarAction.rawValue),
           "add button is an accessory bar action")
    expectTrue(bar.addButton.showsBorderOnlyWhileMouseInside, "add button borders only on hover")
    expectTrue(bar.addButton.pullsDown, "add button is a pull-down")
    // A pull-down draws item 0, not its title: the glyph has to be there.
    expectTrue(bar.addButton.menu?.items.first?.image != nil, "item 0 carries the plus image")
    expect(bar.addButton.menu?.items.count ?? 0, 3, "item 0 plus two real items")
    expect(bar.addButton.menu?.items[1].title ?? "nil", "New Query", "first action is New Query")
    expect(bar.addButton.menu?.items[2].title ?? "nil", "New Folder", "second action is New Folder")

    var newQueries = 0
    var newFolders = 0
    bar.onNewQuery = { newQueries += 1 }
    bar.onNewFolder = { newFolders += 1 }
    if let item = bar.addButton.menu?.items[1] {
        _ = item.target?.perform(item.action, with: item)
    }
    expect(newQueries, 1, "New Query fires its closure")
    expect(newFolders, 0, "New Query does not fire New Folder")
    if let item = bar.addButton.menu?.items[2] {
        _ = item.target?.perform(item.action, with: item)
    }
    expect(newFolders, 1, "New Folder fires its closure")

    // Hiding the pull-down: the stack closes the gap so the field starts at
    // the leading inset, as it must in the two navigators with nothing to add.
    expectTrue(bar.showsAddButton, "the add button shows by default")
    expectFalse(bar.addButton.isHidden, "the add button is visible by default")
    let withButton = bar.filterField.frame.minX
    bar.showsAddButton = false
    expectTrue(bar.addButton.isHidden, "showsAddButton = false hides the pull-down")
    window.contentView?.layoutSubtreeIfNeeded()
    expectTrue(bar.filterField.frame.minX < withButton,
               "the field moves leading when the pull-down goes")
    bar.showsAddButton = true
    expectFalse(bar.addButton.isHidden, "showsAddButton = true brings it back")

    // Typing reaches the owner through the real target/action.
    var texts: [String] = []
    bar.onTextChanged = { texts.append($0) }
    bar.filterField.stringValue = "users"
    _ = bar.filterField.target?.perform(bar.filterField.action, with: bar.filterField)
    expect(texts.count, 1, "one text change reported")
    expect(texts.last ?? "nil", "users", "the text reaches the owner")

    // Focus: the field takes first responder, which is what ⌥⌘J relies on.
    window.makeKeyAndOrderFront(nil)
    bar.focus()
    let responder = window.firstResponder
    let fieldEditor = (responder as? NSTextView)?.delegate as? NSSearchField
    expectTrue(responder === bar.filterField || fieldEditor === bar.filterField,
               "focus() puts first responder in the filter field")
}

private func testPrefs() {
    let suiteName = "SidebarNavigatorTests.\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        failures += 1; print("FAIL could not open a test defaults suite"); return
    }
    let original = SidebarNavigatorPrefs.defaults
    SidebarNavigatorPrefs.defaults = suite
    defer {
        SidebarNavigatorPrefs.defaults = original
        suite.removePersistentDomain(forName: suiteName)
    }

    expectTrue(SidebarNavigatorPrefs.lastNavigator == .library, "an absent key means the library")

    SidebarNavigatorPrefs.lastNavigator = .schema
    expectTrue(SidebarNavigatorPrefs.lastNavigator == .schema, "schema round-trips")
    expect(suite.integer(forKey: "SidebarLastNavigator"), 2, "stored under SidebarLastNavigator")

    SidebarNavigatorPrefs.lastNavigator = .history
    expectTrue(SidebarNavigatorPrefs.lastNavigator == .history, "history round-trips")

    // A value from an older or newer build must not leave the sidebar showing
    // nothing.
    suite.set(99, forKey: "SidebarLastNavigator")
    expectTrue(SidebarNavigatorPrefs.lastNavigator == .library, "an unknown raw value falls back")
    suite.set(-1, forKey: "SidebarLastNavigator")
    expectTrue(SidebarNavigatorPrefs.lastNavigator == .library, "a negative raw value falls back")
    suite.set("folder", forKey: "SidebarLastNavigator")
    expectTrue(SidebarNavigatorPrefs.lastNavigator == .library, "a non-integer value falls back")
}

private func testFilterState() {
    var state = NavigatorFilterState()
    expectTrue(state.current == .library, "state starts on the library")
    expect(state.currentText, "", "no text at rest")

    state.setText("abc")
    expect(state.currentText, "abc", "text lands in the showing navigator's slot")

    state.select(.schema)
    expect(state.currentText, "", "a fresh navigator starts empty")
    state.setText("public")
    expect(state.currentText, "public", "the schema navigator keeps its own text")

    state.select(.library)
    expect(state.currentText, "abc", "the library's text comes back")
    state.select(.schema)
    expect(state.currentText, "public", "the schema's text comes back")

    state.select(.history)
    expect(state.currentText, "", "the history navigator was never typed in")
    expect(state.text(for: .library), "abc", "library text readable while hidden")
    expect(state.text(for: .schema), "public", "schema text readable while hidden")

    // Clearing is a real value, not an absence: it must stick.
    state.select(.library)
    state.setText("")
    expect(state.currentText, "", "a cleared filter stays cleared")
    state.select(.schema)
    state.select(.library)
    expect(state.currentText, "", "a cleared filter survives a round trip")

    // Seeding from the preference.
    let seeded = NavigatorFilterState(current: .history)
    expectTrue(seeded.current == .history, "the state can be seeded")
}

func runTests() {
    testNavigatorModel()
    testNavigatorToolbarGroup()
    testFilterBar()
    testPrefs()
    testFilterState()

    if failures == 0 { print("\nAll sidebar navigator tests passed.") }
    else { print("\n\(failures) failure(s).") ; exit(1) }
}
