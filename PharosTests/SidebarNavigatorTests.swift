// Standalone tests for the sidebar's navigator selector, its bottom filter
// bar, and the state behind both — compiled by
// scripts/test-sidebar-navigator.sh.
//
// What this suite is FOR. Three things here can fail silently:
//
// 1. The selector stops being a radio group. `NSButton` push-on/push-off
//    buttons are three independent toggles unless something re-asserts the
//    single-selection rule, and the failure (two icons lit, or none) is
//    invisible to a compiler. Every selection assertion here goes through
//    `performClick` — the real target/action — which is why the buttons are
//    hosted in an offscreen NSWindow.
// 2. The flat Xcode look quietly reverts. `bezelStyle` and
//    `showsBorderOnlyWhileMouseInside` are the two properties that carry it;
//    either one changed puts a bezel back under every icon.
// 3. A filter follows the user across a navigator switch. The schema tree and
//    the query history match on different text, so a carried-over filter
//    reads as an empty list rather than as a mistake.
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

private func onCount(_ selector: NavigatorSelector) -> Int {
    Navigator.allCases.filter { selector.button(for: $0)?.state == .on }.count
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

    expect(Navigator.library.accessibilityIdentifier, "sidebar.navigator.library", "library identifier")
    expect(Navigator.history.accessibilityIdentifier, "sidebar.navigator.history", "history identifier")
    expect(Navigator.schema.accessibilityIdentifier, "sidebar.navigator.schema", "schema identifier")
}

private func testSelectorAppearance() {
    let selector = NavigatorSelector()
    let window = host(selector)
    defer { window.close() }

    // A plain NSView is an ignored accessibility element: without
    // setAccessibilityElement(true) none of the three below would surface.
    expectTrue(selector.isAccessibilityElement(), "selector is an accessibility element")
    expect(selector.accessibilityRole()?.rawValue ?? "nil",
           NSAccessibility.Role.radioGroup.rawValue, "selector is a radio group")
    expect(selector.accessibilityLabel() ?? "nil", "Navigators", "selector label")
    expect(selector.accessibilityIdentifier(), "sidebar.navigator", "selector identifier")

    for navigator in Navigator.allCases {
        guard let button = selector.button(for: navigator) else {
            failures += 1; print("FAIL no button for \(navigator)"); continue
        }
        // The two properties that carry the flat Xcode look. `.accessoryBar`
        // with showsBorderOnlyWhileMouseInside draws nothing when off and a
        // neutral rounded fill when on; changing either puts a bezel back.
        expect(Int(button.bezelStyle.rawValue), Int(NSButton.BezelStyle.accessoryBar.rawValue),
               "\(navigator) button is an accessory bar button")
        expectTrue(button.showsBorderOnlyWhileMouseInside,
                   "\(navigator) button borders only on hover")
        expect(Int(button.imagePosition.rawValue), Int(NSControl.ImagePosition.imageOnly.rawValue),
               "\(navigator) button is image only")
        expectTrue(button.image != nil, "\(navigator) button has an image")
        expect(button.toolTip ?? "nil", navigator.title, "\(navigator) tooltip is the title")
        expect(button.accessibilityRole()?.rawValue ?? "nil",
               NSAccessibility.Role.radioButton.rawValue, "\(navigator) is a radio button")
        expect(button.accessibilityLabel() ?? "nil", navigator.title, "\(navigator) AX label")
        expect(button.accessibilityIdentifier(), navigator.accessibilityIdentifier,
               "\(navigator) AX identifier")
        // Auto Layout pins the ALIGNMENT RECT, not the frame: an image-only
        // button's frame carries the symbol's insets on top.
        let rect = button.alignmentRect(forFrame: button.frame)
        expect(rect.width, 28, "\(navigator) button is 28 wide")
        expect(rect.height, 24, "\(navigator) button is 24 tall")
    }

    // The stack the row is built from, found by walking rather than exposed:
    // .equalCentering is what spreads three icons evenly across the sidebar.
    let stacks = selector.subviews.compactMap { $0 as? NSStackView }
    expect(stacks.count, 1, "one stack in the selector")
    if let stack = stacks.first {
        expect(Int(stack.distribution.rawValue), Int(NSStackView.Distribution.equalCentering.rawValue),
               "selector stack centres equally")
        expect(stack.edgeInsets.left, 8, "selector stack leading inset")
        expect(stack.edgeInsets.right, 8, "selector stack trailing inset")
    }
    expect(selector.alignmentRect(forFrame: selector.frame).height, 28, "selector row is 28 tall")
}

private func testSelectorIsARadioGroup() {
    let selector = NavigatorSelector()
    let window = host(selector)
    defer { window.close() }

    var changes: [Navigator] = []
    selector.onChange = { changes.append($0) }

    expect(onCount(selector), 1, "exactly one button on at rest")
    expectTrue(selector.button(for: .library)?.state == .on, "library starts on")

    selector.button(for: .history)?.performClick(nil)
    expect(onCount(selector), 1, "exactly one button on after clicking history")
    expectTrue(selector.button(for: .history)?.state == .on, "history is on")
    expect(changes.count, 1, "one change reported")
    expectTrue(changes.last == .history, "the change names history")
    expectTrue(selector.selected == .history, "selected follows the click")

    selector.button(for: .schema)?.performClick(nil)
    expect(onCount(selector), 1, "exactly one button on after clicking schema")
    expectTrue(selector.button(for: .schema)?.state == .on, "schema is on")
    expect(changes.count, 2, "two changes reported")

    // The failure this guards: a push-on/push-off button toggles itself off on
    // the way in, so a click on the SHOWING navigator would blank the row and
    // leave the sidebar on a list no icon claims.
    selector.button(for: .schema)?.performClick(nil)
    expect(onCount(selector), 1, "re-clicking the selected button leaves one on")
    expectTrue(selector.button(for: .schema)?.state == .on, "schema stays on after a re-click")
    expect(changes.count, 2, "a re-click reports no change")

    selector.button(for: .library)?.performClick(nil)
    expect(onCount(selector), 1, "exactly one on back at library")
    expect(changes.count, 3, "three changes reported")

    // Setting the property must move the highlight too — the menu drives it
    // this way, not by clicking.
    selector.selected = .history
    expect(onCount(selector), 1, "one on after setting the property")
    expectTrue(selector.button(for: .history)?.state == .on, "the property moves the highlight")
    expect(changes.count, 3, "setting the property fires no change callback")
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
    testSelectorAppearance()
    testSelectorIsARadioGroup()
    testFilterBar()
    testPrefs()
    testFilterState()

    if failures == 0 { print("\nAll sidebar navigator tests passed.") }
    else { print("\n\(failures) failure(s).") ; exit(1) }
}
