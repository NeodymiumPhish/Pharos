// Standalone test runner for ErrorBadgeButton. Unlike the pure-logic runners,
// this one uses real AppKit: it hosts the toolbar trailing group in a headless,
// never-shown NSWindow so Auto Layout runs a real pass. An unhosted view never
// lays out, so measuring one would prove nothing.
// Compiled with ErrorBadgeButton.swift and PulseClock.swift by
// scripts/test-error-badge-button.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.01) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

func runTests() {
    // MARK: regression — setState must tint even when the pulse state doesn't change

    // `setPulsing` early-returns when the pulse flag doesn't flip, so a button
    // whose very first call to `setState` lands on "quiet" (not pulsing, same as
    // its initial `isPulsing == false`) must still get tinted by `setState`
    // itself, not by a branch inside `setPulsing`.
    let freshButton = ErrorBadgeButton()
    freshButton.setState(total: 3, unread: 0)
    expectTrue(freshButton.contentTintColor != nil,
               "setState tints the button even on its first call with no pulse-state change")

    // MARK: states

    let button = ErrorBadgeButton()
    button.setState(total: 0, unread: 0)
    expectTrue(button.isHidden, "the button is hidden with no entries")

    button.setState(total: 3, unread: 0)
    expectTrue(!button.isHidden, "the button shows when the log holds entries")
    expectTrue(!button.isPulsing, "a fully read log does not pulse")
    expectString(button.title, "3", "the title holds the count")
    expectString(button.toolTip ?? "", "Query Errors (3)", "the tool tip names the count")

    button.setState(total: 1, unread: 0)
    expectString(button.title, "", "a single entry needs no count in the title")

    button.setState(total: 3, unread: 1)
    expectTrue(button.isPulsing, "an unread entry starts the pulse")
    expectString(button.toolTip ?? "", "Query Errors (3, 1 new)", "the tool tip names the unread count")

    // The clock's subject is the pulse source, so a test can step it by hand.
    PulseClock.shared.value.send(0.0)
    expectClose(button.pulseAlpha, 0.55, "the trough of the pulse is 0.55")
    PulseClock.shared.value.send(1.0)
    expectClose(button.pulseAlpha, 1.0, "the peak of the pulse is 1.0")

    button.setState(total: 3, unread: 0)
    expectTrue(!button.isPulsing, "the pulse stops when the user reads the last unread entry")
    PulseClock.shared.value.send(0.0)
    expectClose(button.pulseAlpha, 1.0, "a stopped pulse ignores the clock")

    button.setState(total: 0, unread: 0)
    expectTrue(button.isHidden && !button.isPulsing, "an emptied log hides the button and stops the pulse")

    // MARK: toolbar trailing group

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 32),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
    window.contentView = container

    let errorButton = ErrorBadgeButton()
    errorButton.setState(total: 2, unread: 1)
    let resultTabsToggle = NSButton()
    resultTabsToggle.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: nil)
    resultTabsToggle.isBordered = false

    let group = ErrorBadgeButton.makeToolbarTrailingGroup(
        errorButton: errorButton, resultTabsToggle: resultTabsToggle
    )
    container.addSubview(group)
    NSLayoutConstraint.activate([
        group.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        group.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    container.layoutSubtreeIfNeeded()

    // Two buttons, in the order the editor toolbar reads left to right: the
    // error badge, then the result-tabs toggle.
    expectTrue(group.arrangedSubviews.count == 2, "the trailing group holds exactly two buttons")
    expectTrue(errorButton.frame.maxX <= resultTabsToggle.frame.minX,
               "the error button sits to the left of the result-tabs toggle")
    // resultTabsToggle.frame is expressed in its immediate superview's space —
    // the stack, not the container — so it must be converted before comparing
    // against container.bounds.
    let toggleFrameInContainer = resultTabsToggle.convert(resultTabsToggle.bounds, to: container)
    expectClose(container.bounds.maxX - toggleFrameInContainer.maxX, 8,
                "the result-tabs toggle keeps its 8 pt trailing inset", tolerance: 0.5)
    // Auto Layout sizes a button's ALIGNMENT RECT, and an image-only NSButton
    // carries non-zero vertical alignmentRectInsets, so its frame is a few
    // points taller than the constraint. Measure what the constraint governs.
    let alignmentRect = resultTabsToggle.alignmentRect(forFrame: resultTabsToggle.frame)
    expectClose(alignmentRect.width, 24, "the result-tabs toggle is 24pt wide", tolerance: 0.5)
    expectClose(alignmentRect.height, 24, "the result-tabs toggle is 24pt tall", tolerance: 0.5)
    expectTrue(errorButton.frame.width >= 24, "the error button is at least 24 pt wide")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
