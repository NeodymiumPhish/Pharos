// Standalone test runner for VariablesPanelPrefs. Not part of the app target —
// compiled together with the implementation by scripts/test-variables-panel-prefs.sh.
//
// These cover the preference *logic* only: first-run defaulting, stickiness, and
// width clamping. Whether the panel actually appears is a UI behaviour verified by
// running the app — see the plan's Task 3 step 6.
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

private let widthKey = "QueryVariablesPanelWidth"
private let visibleKey = "QueryVariablesPanelVisibleByDefault"

private func clearKeys() {
    UserDefaults.standard.removeObject(forKey: widthKey)
    UserDefaults.standard.removeObject(forKey: visibleKey)
}

func runTests() {
    clearKeys()

    // First run: the key is absent, and absent must mean "open". This is the whole
    // point of reading object(forKey:) rather than bool(forKey:) — the latter
    // returns false for a missing key, which would ship the panel closed.
    expectTrue(VariablesPanelPrefs.visibleByDefault, "absent key defaults to visible")

    // Stickiness: an explicit false must survive, and must not be mistaken for absent.
    VariablesPanelPrefs.visibleByDefault = false
    expectFalse(VariablesPanelPrefs.visibleByDefault, "an explicit false is honoured")
    VariablesPanelPrefs.visibleByDefault = true
    expectTrue(VariablesPanelPrefs.visibleByDefault, "an explicit true is honoured")

    // Clearing the key returns to the first-run answer rather than to the last value.
    UserDefaults.standard.removeObject(forKey: visibleKey)
    expectTrue(VariablesPanelPrefs.visibleByDefault, "clearing the key restores the default")

    // Width: absent key yields the default rather than 0, which is what a bare
    // double(forKey:) would give and would collapse the panel to nothing.
    clearKeys()
    expectEqual("\(VariablesPanelPrefs.width)", "\(VariablesPanelPrefs.defaultWidth)",
                "absent width key yields the default")

    // Clamping on write and on read, at both ends.
    VariablesPanelPrefs.width = 50
    expectEqual("\(VariablesPanelPrefs.width)", "\(VariablesPanelPrefs.minWidth)", "a too-narrow width clamps up to minWidth")
    VariablesPanelPrefs.width = 5000
    expectEqual("\(VariablesPanelPrefs.width)", "\(VariablesPanelPrefs.maxWidth)", "a too-wide width clamps down to maxWidth")

    // A sane width round-trips untouched.
    VariablesPanelPrefs.width = 320
    expectEqual("\(VariablesPanelPrefs.width)", "320.0", "an in-range width round-trips")

    // A value stored out of range by an older build is clamped on read, not trusted.
    UserDefaults.standard.set(9999.0, forKey: widthKey)
    expectEqual("\(VariablesPanelPrefs.width)", "\(VariablesPanelPrefs.maxWidth)", "an out-of-range stored width is clamped on read")

    clearKeys()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
