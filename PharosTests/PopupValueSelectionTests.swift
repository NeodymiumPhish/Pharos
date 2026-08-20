// Standalone tests for PopupValueSelection — the read-back rule for a popup
// whose titles are escaped for display and whose real values ride along in
// `representedObject`. Uses real NSPopUpButton/NSMenuItem objects; no window.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func makePopup(_ items: [(title: String, value: String?)]) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.removeAllItems()
    for item in items {
        popup.addItem(withTitle: item.title)
        popup.lastItem?.representedObject = item.value
    }
    return popup
}

func runTests() {
    // The value comes from representedObject, never from the displayed title —
    // that is the whole point: the title is escaped and the value is not.
    let popup = makePopup([
        (title: "None", value: nil),
        (title: "public", value: "public"),
        (title: "sales<U+200B>", value: "sales\u{200B}"),
    ])

    popup.selectItem(at: 1)
    expectEqual(PopupValueSelection.selectedValue(in: popup), "public",
                "an ordinary selection returns its raw value")

    popup.selectItem(at: 2)
    expectEqual(PopupValueSelection.selectedValue(in: popup), "sales\u{200B}",
                "a hostile selection returns the RAW value, not the escaped title")

    popup.selectItem(at: 0)
    expectEqual(PopupValueSelection.selectedValue(in: popup), nil,
                "a sentinel row carries no value")

    // A row whose value was never set must not fall back to its title: a silent
    // fallback is how the escaped string would reach the store.
    let unset = NSPopUpButton(frame: .zero, pullsDown: false)
    unset.addItem(withTitle: "public\u{200B}")
    unset.selectItem(at: 0)
    expectEqual(PopupValueSelection.selectedValue(in: unset), nil,
                "no representedObject means no value — never the title")

    let empty = NSPopUpButton(frame: .zero, pullsDown: false)
    empty.removeAllItems()
    expectEqual(PopupValueSelection.selectedValue(in: empty), nil,
                "an empty popup has no value")

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
