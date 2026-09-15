// Standalone tests for the gutter's error popover — the message shown where
// the error is, and the "Go to Error" button that puts the caret on it.
//
// The popover itself needs a window to anchor to, and a headless binary has no
// screen to show one on. These tests therefore drive the two seams the popover
// is built from: `makeErrorPopoverContent(forLine:)`, which builds the content
// view controller, and `presentErrorPopover(line:)`, which is what both the
// click path and the accessibility press call.
//
// Compiled by scripts/test-gutter-error-popover.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectEqual(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Harness

private let sql = """
select 1;
select *
from nope_table;
"""

private func makeHostedGutter() -> (window: NSWindow, gutter: LineNumberGutter, textView: NSTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    window.contentView = container

    let scrollView = NSScrollView(frame: NSRect(x: 50, y: 0, width: 450, height: 300))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.string = sql
    scrollView.documentView = textView

    let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
    gutter.frame = NSRect(x: 0, y: 0, width: gutter.desiredWidth, height: 300)
    container.addSubview(gutter)
    container.addSubview(scrollView)

    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    container.layoutSubtreeIfNeeded()
    gutter.invalidateLineNumbers()

    return (window, gutter, textView)
}

private let message = "relation \"nope_table\" does not exist"

// MARK: - Tests

func runTests() {
    let (window, gutter, _) = makeHostedGutter()
    _ = window

    gutter.setErrors([3: message])

    // --- Content: the message, verbatim, in the popover ---
    guard let content = gutter.makeErrorPopoverContent(forLine: 3) else {
        print("FAIL no content built for the error line")
        exit(1)
    }
    // loadView runs on first `view` access; the labels are only populated there.
    _ = content.view
    expectEqual(content.messageLabel.stringValue, message,
                "popover shows the failure message")
    expectEqual(content.line, 3, "content names the line it speaks for")
    expectEqual(content.goToErrorButton.title, "Go to Error", "the button is offered")
    expectTrue(content.messageLabel.isSelectable, "the message is selectable")
    expectTrue(content.messageLabel.maximumNumberOfLines == 0,
               "the message wraps rather than truncating")
    expectTrue(content.messageLabel.font?.isFixedPitch == true,
               "the message is monospaced — it quotes SQL")
    expectEqual(Int(content.messageLabel.font?.pointSize ?? 0), 12, "message is 12 pt")
    expectTrue(LineNumberGutter.ErrorPopoverVC.maxContentWidth == 420,
               "content width caps at 420")

    // The laid-out content honours BOTH bounds. A long message must not
    // stretch the popover off the display, and must not be squeezed into a
    // narrow column either — measured live, an unfloored wrapping label chose
    // 128 pt and stacked one sentence into eight fragments.
    gutter.setErrors([3: String(repeating: "syntax error at or near \"x\". ", count: 12)])
    let wide = gutter.makeErrorPopoverContent(forLine: 3)!
    _ = wide.view
    wide.view.layoutSubtreeIfNeeded()
    let wideWidth = wide.view.fittingSize.width
    expectTrue(wideWidth <= LineNumberGutter.ErrorPopoverVC.maxContentWidth + 24 + 1,
               "a long message wraps inside the cap — got \(wideWidth)")
    expectTrue(wideWidth >= LineNumberGutter.ErrorPopoverVC.minContentWidth,
               "a long message is not squeezed below the floor — got \(wideWidth)")

    // A short message keeps a small popover: the floor is not a fixed width.
    gutter.setErrors([3: "no such table"])
    let narrow = gutter.makeErrorPopoverContent(forLine: 3)!
    _ = narrow.view
    narrow.view.layoutSubtreeIfNeeded()
    expectTrue(narrow.view.fittingSize.width < LineNumberGutter.ErrorPopoverVC.minContentWidth,
               "a short message does not claim the floor — got \(narrow.view.fittingSize.width)")
    gutter.setErrors([3: message])

    // --- A line with no error offers nothing ---
    expectTrue(gutter.makeErrorPopoverContent(forLine: 1) == nil,
               "a clean line has no popover content")
    expectTrue(gutter.presentErrorPopover(line: 1) == false,
               "presenting on a clean line is refused")

    // --- Go to Error reports the line back to the host ---
    var revealed: Int?
    gutter.onRevealError = { revealed = $0 }
    content.performGoToError()
    expectEqual(revealed ?? -1, 3, "Go to Error fires onRevealError with the marker's line")

    // --- A message-free error still shows something ---
    gutter.setErrorLines([2])
    let bare = gutter.makeErrorPopoverContent(forLine: 2)
    _ = bare?.view
    expectEqual(bare?.messageLabel.stringValue ?? "(none)", "Error",
                "a message-free error falls back to \"Error\"")

    // --- The accessibility marker presses into the popover ---
    gutter.setErrors([3: message])
    let errorElement = (gutter.accessibilityChildren() as? [LineNumberGutter.GutterElement])?
        .first { $0.accessibilityRole() == .image }
    expectTrue(errorElement != nil, "the error marker is an accessibility child")
    expectTrue(errorElement?.accessibilityPerformPress() == true,
               "pressing the error marker opens the popover")

    // --- Clearing the errors takes the popover with them ---
    gutter.clearErrors()
    expectTrue(gutter.makeErrorPopoverContent(forLine: 3) == nil,
               "no content once the error is cleared")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
