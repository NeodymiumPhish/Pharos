// Standalone tests for HostileTextBadge — the disclosure that stands beside a
// field whose contents must never be altered.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    _ = NSApplication.shared

    // Ordinary text: no badge, no tooltip.
    do {
        let badge = HostileTextBadge()
        badge.update(for: "db.example.com")
        expectEqual(badge.isHidden, true, "ordinary text shows no badge")
        expectEqual(badge.toolTip, nil, "and carries no tooltip")
    }

    // A hostile scalar: the badge appears and its tooltip discloses the text.
    do {
        let badge = HostileTextBadge()
        badge.update(for: "db\u{200B}.example.com")
        expectEqual(badge.isHidden, false, "a zero-width character raises the badge")
        expectTrue(badge.toolTip?.contains("<U+200B>") == true,
                   "the tooltip shows the escaped form, which the field cannot")
    }

    // An edge space is exactly the case a field cannot show.
    do {
        let badge = HostileTextBadge()
        badge.update(for: "db.example.com ")
        expectEqual(badge.isHidden, false, "a trailing space raises the badge")
    }

    // Recycled state: a badge must come DOWN again, or a stale warning
    // outlives the value that caused it.
    do {
        let badge = HostileTextBadge()
        badge.update(for: "bad\u{202E}value")
        badge.update(for: "clean")
        expectEqual(badge.isHidden, true, "the badge is lowered when the text is clean again")
        expectEqual(badge.toolTip, nil, "and its tooltip is cleared with it")
    }

    // Empty is clean.
    do {
        let badge = HostileTextBadge()
        badge.update(for: "")
        expectEqual(badge.isHidden, true, "an empty field shows no badge")
    }

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
