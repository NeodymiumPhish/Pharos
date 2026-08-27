// Standalone test runner for ResultTabsPanelPrefs. Not part of the app target —
// compiled together with the implementation by scripts/test-result-tabs-panel-prefs.sh.
//
// These cover the preference logic only: first-run defaulting, stickiness, and
// width clamping. Whether the panel actually appears is a UI behaviour verified
// by running the app.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

private let widthKey = "ResultTabsPanelWidth"
private let visibleKey = "ResultTabsPanelVisibleByDefault"

private func clearKeys() {
    UserDefaults.standard.removeObject(forKey: widthKey)
    UserDefaults.standard.removeObject(forKey: visibleKey)
}

func runTests() {
    clearKeys()

    // First run: an absent key must mean "open" — the panel ships visible.
    // object(forKey:) rather than bool(forKey:), which returns false when absent.
    expectTrue(ResultTabsPanelPrefs.visibleByDefault, "absent key defaults to visible")

    // Stickiness: an explicit false must survive and not be mistaken for absent.
    ResultTabsPanelPrefs.visibleByDefault = false
    expectFalse(ResultTabsPanelPrefs.visibleByDefault, "an explicit false is honoured")
    ResultTabsPanelPrefs.visibleByDefault = true
    expectTrue(ResultTabsPanelPrefs.visibleByDefault, "an explicit true is honoured")
    UserDefaults.standard.removeObject(forKey: visibleKey)
    expectTrue(ResultTabsPanelPrefs.visibleByDefault, "clearing the key restores the default")

    // Width: absent key yields the default rather than 0.
    clearKeys()
    expectEqual("\(ResultTabsPanelPrefs.width)", "\(ResultTabsPanelPrefs.defaultWidth)",
                "absent width key yields the default")

    ResultTabsPanelPrefs.width = 50
    expectEqual("\(ResultTabsPanelPrefs.width)", "\(ResultTabsPanelPrefs.minWidth)",
                "a too-narrow width clamps up to minWidth")
    ResultTabsPanelPrefs.width = 5000
    expectEqual("\(ResultTabsPanelPrefs.width)", "\(ResultTabsPanelPrefs.maxWidth)",
                "a too-wide width clamps down to maxWidth")

    ResultTabsPanelPrefs.width = 320
    expectEqual("\(ResultTabsPanelPrefs.width)", "320.0", "an in-range width round-trips")

    // A value stored out of range by an older build is clamped on read, not trusted.
    UserDefaults.standard.set(9999.0, forKey: widthKey)
    expectEqual("\(ResultTabsPanelPrefs.width)", "\(ResultTabsPanelPrefs.maxWidth)",
                "an out-of-range stored width is clamped on read")

    clearKeys()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
