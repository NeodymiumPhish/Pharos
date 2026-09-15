// What the horizontal result tab bar publishes to a screen reader.
//
// The bar draws everything: the tabs are not buttons, the close glyph is not a
// button, and the colour dot is not anything at all. Before this suite the whole
// bar was one unlabelled rectangle, so these assertions are the only proof that
// a tab can be named, selected and closed without a mouse.
//
// Real AppKit in a headless, never-shown NSWindow — the window is not optional:
// an accessibility frame is in SCREEN coordinates, and a view with no window
// has no screen to convert through.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name) [\(actual ?? "nil")]") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")")
    }
}

private func makeTab(id: String, label: String, color: NSColor, stale: Bool = false) -> ResultTab {
    var tab = ResultTab(id: id, segmentIndex: 0, sql: "select 1", rawSQL: "select 1",
                        lineRange: 1...1, color: color, timestamp: Date())
    tab.customLabel = label
    tab.isStale = stale
    return tab
}

private func makeBar() -> ResultTabBar {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    window.contentView = host
    let bar = ResultTabBar(frame: NSRect(x: 0, y: 0, width: 600, height: 26))
    host.addSubview(bar)
    return bar
}

private func intValue(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue
}

func runTests() {
    let bar = makeBar()
    var selected: [String] = []
    var closed: [String] = []
    bar.onSelectTab = { selected.append($0) }
    bar.onCloseTab = { closed.append($0) }

    bar.update(tabs: [
        makeTab(id: "t1", label: "Query A", color: .systemBlue),
        makeTab(id: "t2", label: "Query B", color: .systemPurple, stale: true),
    ], activeTabId: "t1")
    bar.layoutSubtreeIfNeeded()

    // 1. The bar itself.
    expect(bar.accessibilityRole() == .tabGroup, "the bar is a tab group")
    expectEqual(bar.accessibilityIdentifier(), "results.tabBar", "the bar carries its identifier")

    let buttons = (bar.accessibilityChildren() ?? []).compactMap { $0 as? ResultTabButton }
    expect(buttons.count == 2, "the tab group publishes one child per tab [\(buttons.count)]")
    guard buttons.count == 2 else {
        print("\n\(failures + 1) FAILURE(S)")
        exit(1)
    }

    // 2. Each tab.
    expect(buttons[0].accessibilityRole() == .radioButton, "a tab is a radio button")
    expectEqual(buttons[0].accessibilityLabel(), "Query A", "a tab is named by its label")
    expectEqual(buttons[1].accessibilityLabel(), "Query B, stale",
                "a stale tab says so — the only other channel is a 40% dot")
    expect(intValue(buttons[0].accessibilityValue()) == 1, "the active tab's value is 1")
    expect(intValue(buttons[1].accessibilityValue()) == 0, "an inactive tab's value is 0")

    // 3. Press selects.
    expect(buttons[1].accessibilityPerformPress(), "pressing a tab reports that it acted")
    expect(selected == ["t2"], "pressing a tab selects it [\(selected)]")

    // 4. The close glyph, which is drawn and is not even painted until hover.
    let closeChildren = (buttons[0].accessibilityChildren() ?? [])
        .compactMap { $0 as? AccessibilityProxyElement }
    expect(closeChildren.count == 1, "each tab publishes exactly one close element [\(closeChildren.count)]")
    guard let close = closeChildren.first else {
        print("\n\(failures + 1) FAILURE(S)")
        exit(1)
    }
    expect(close.accessibilityRole() == .button, "the close element is a button")
    expectEqual(close.accessibilityLabel(), "Close Query A", "the close element names its tab")
    expect(close.accessibilityFrame() != .zero, "the close element has a real screen frame")
    expect(close.accessibilityPerformPress(), "pressing close reports that it acted")
    expect(closed == ["t1"], "pressing close closes that tab [\(closed)]")

    // 5. The close element is reachable by pointer, and the rest of the tab is
    //    not the close.
    let closeCentre = buttons[0].closeRect.centre(in: buttons[0])
    expect(buttons[0].accessibilityHitTest(closeCentre) as? AccessibilityProxyElement === close,
           "a hit on the close glyph finds the close element")
    let labelPoint = NSRect(x: 0, y: 0, width: 4, height: buttons[0].bounds.height).centre(in: buttons[0])
    expect(buttons[0].accessibilityHitTest(labelPoint) as? ResultTabButton === buttons[0],
           "a hit elsewhere on the tab finds the tab")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

private extension NSRect {
    /// This rect's centre in SCREEN coordinates — what `accessibilityHitTest`
    /// is handed by a real accessibility client.
    func centre(in view: NSView) -> NSPoint {
        let local = NSPoint(x: midX, y: midY)
        let inWindow = view.convert(local, to: nil)
        return view.window?.convertPoint(toScreen: inWindow) ?? inWindow
    }
}
