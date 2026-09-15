// Standalone test for `PendingEditsBar` — compiled by
// scripts/test-pending-edits-bar.sh. Uses real AppKit through a headless
// NSWindow, like scripts/test-import-data-sheet.sh.
//
// What this suite is FOR: the bar is the ONLY thing on screen that says the
// app is holding changes the user has not written. Three ways it could fail
// quietly, all asserted below.
//
// 1. It stays on screen with nothing pending (or goes away with something
//    pending). `show(changeCount: 0)` hiding itself is what lets the owner
//    call one method for both cases and never get that wrong.
// 2. Its buttons do nothing. Both are driven here by `performClick`, through
//    the real target/action, not by calling the closures directly.
// 3. VoiceOver cannot see it. A plain NSView is an IGNORED accessibility
//    element, so without `setAccessibilityElement(true)` the role, the label
//    and the identifier are all set and none of them appears in the tree —
//    which is exactly the trap this project has hit before.
import AppKit

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Host

/// The bar inside a window, laid out the way `ContentViewController` lays it
/// out: full width, and a height constraint the owner drives between 0 and
/// `PendingEditsBar.height`.
private final class Host {
    let window: NSWindow
    let bar = PendingEditsBar()
    let heightConstraint: NSLayoutConstraint

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = content
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        heightConstraint = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            heightConstraint,
        ])
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// What the owner does: one call for the count, and the height follows.
    func apply(changeCount: Int, table: String = "public.users") {
        if changeCount > 0 {
            bar.show(changeCount: changeCount, tableDisplay: table)
            heightConstraint.constant = PendingEditsBar.height
        } else {
            bar.hide()
            heightConstraint.constant = 0
        }
        layout()
    }
}

// MARK: - Height and visibility

private func testEmptyBarTakesNoHeight() {
    let host = Host()
    host.apply(changeCount: 0)
    expectTrue(host.bar.isHidden, "with nothing pending the bar is hidden")
    // Auto Layout sizes the ALIGNMENT RECT, so measure that and not the frame.
    expect(host.bar.alignmentRect(forFrame: host.bar.frame).height, 0,
           "and takes no height at all")
    expect(host.bar.messageText, "", "and says nothing")
}

private func testBarWithEditsIs28Points() {
    let host = Host()
    host.apply(changeCount: 3)
    expectTrue(!host.bar.isHidden, "with changes pending the bar is visible")
    expect(host.bar.alignmentRect(forFrame: host.bar.frame).height, PendingEditsBar.height,
           "and stands at its one height")
    expect(PendingEditsBar.height, 28, "which is 28 points")
    expect(host.bar.frame.width, 600, "and spans the results area")
}

private func testGoingBackToZeroHidesItAgain() {
    let host = Host()
    host.apply(changeCount: 2)
    host.apply(changeCount: 0)
    expectTrue(host.bar.isHidden, "applying the last change takes the bar away")
    expect(host.bar.alignmentRect(forFrame: host.bar.frame).height, 0, "and gives the height back")
}

private func testShowWithZeroHidesRatherThanShowingNothing() {
    // The owner must be able to call one method for both cases.
    let host = Host()
    host.bar.show(changeCount: 1, tableDisplay: "public.users")
    host.bar.show(changeCount: 0, tableDisplay: "public.users")
    expectTrue(host.bar.isHidden, "show(changeCount: 0) hides the bar")
}

// MARK: - Text

private func testMessageText() {
    expect(PendingEditsBar.message(changeCount: 1, tableDisplay: "public.users"),
           "1 change in public.users", "one change reads in the singular")
    expect(PendingEditsBar.message(changeCount: 3, tableDisplay: "public.users"),
           "3 changes in public.users", "three changes read in the plural")
    expect(PendingEditsBar.message(changeCount: 0, tableDisplay: "public.users"),
           "0 changes in public.users", "and zero reads in the plural too")
    expect(PendingEditsBar.message(changeCount: 2, tableDisplay: ""),
           "2 changes", "with no table name the bar still counts")
}

private func testTheLabelIsWhatIsOnScreen() {
    let host = Host()
    host.apply(changeCount: 3)
    expect(host.bar.messageText, "3 changes in public.users", "the label shows the count and the table")
    expect(host.bar.toolTip ?? "", "3 changes in public.users", "and so does the tooltip")
}

// MARK: - Buttons

private func testButtonsAreWired() {
    let host = Host()
    host.apply(changeCount: 1)
    var reviewed = 0
    var discarded = 0
    host.bar.onReview = { reviewed += 1 }
    host.bar.onDiscard = { discarded += 1 }

    // Through the real target/action, not by calling the closures.
    host.bar.reviewButtonForTesting.performClick(nil)
    host.bar.discardButtonForTesting.performClick(nil)
    expectTrue(reviewed == 1, "Review Changes… calls its handler exactly once")
    expectTrue(discarded == 1, "Discard calls its handler exactly once")

    expect(host.bar.reviewButtonForTesting.title, "Review Changes…", "the review button is named for what it opens")
    expect(host.bar.discardButtonForTesting.title, "Discard", "and the discard button for what it does")
    expectTrue(!(host.bar.reviewButtonForTesting.toolTip ?? "").isEmpty,
               "the review button explains itself on hover")
    expectTrue(!(host.bar.discardButtonForTesting.toolTip ?? "").isEmpty,
               "and so does the discard button")
}

private func testButtonsStayInsideTheBar() {
    let host = Host()
    host.apply(changeCount: 12)
    let bar = host.bar
    for (button, name) in [(bar.reviewButtonForTesting, "review"), (bar.discardButtonForTesting, "discard")] {
        // Convert before comparing: the buttons sit inside a stack view, so
        // their frames are in the stack's space, not the bar's.
        let inBar = button.convert(button.bounds, to: bar)
        expectTrue(inBar.maxX <= bar.bounds.maxX + 0.5 && inBar.minX >= bar.bounds.minX,
                   "the \(name) button stays inside the bar horizontally")
        expectTrue(inBar.minY >= bar.bounds.minY - 0.5 && inBar.maxY <= bar.bounds.maxY + 0.5,
                   "the \(name) button stays inside the bar vertically")
    }
}

// MARK: - Accessibility

private func testAccessibility() {
    let host = Host()
    host.apply(changeCount: 3)
    expectTrue(host.bar.isAccessibilityElement(),
               "the bar is an accessibility element (a plain NSView is ignored by default)")
    expectTrue(host.bar.accessibilityRole() == .group, "its role is a group")
    expect(host.bar.accessibilityIdentifier(), "results.pendingEdits",
           "and it has the stable identifier a driver finds it by")
    expect(host.bar.accessibilityLabelForTesting, "3 changes in public.users",
           "its label is the sentence on screen, so a screen reader hears the count")
    expect(host.bar.reviewButtonForTesting.accessibilityIdentifier(), "results.pendingEdits.review",
           "the review button is findable by name")
    expect(host.bar.discardButtonForTesting.accessibilityIdentifier(), "results.pendingEdits.discard",
           "and so is the discard button")
}

func runTests() {
    testEmptyBarTakesNoHeight()
    testBarWithEditsIs28Points()
    testGoingBackToZeroHidesItAgain()
    testShowWithZeroHidesRatherThanShowingNothing()
    testMessageText()
    testTheLabelIsWhatIsOnScreen()
    testButtonsAreWired()
    testButtonsStayInsideTheBar()
    testAccessibility()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
