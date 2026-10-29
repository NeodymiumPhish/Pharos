// Standalone tests for the Inspector's row-detail value label.
//
// A value is selectable: a drag selects some characters and ⌘C copies them.
// The double-click must still copy the WHOLE raw value — also when the window's
// field editor already sits on the label from an earlier click, because then
// the second click goes to the editor, not to the label — and the editor's
// context menu must still offer that copy.
//
// The events go through NSApplication.sendEvent, the real dispatch path: the
// window sends the second click of a double-click to the view that took the
// first, which a direct `mouseDown` call would not show. The window must be
// on screen for that (at -20000, -20000, so nothing shows).
//
// Compiled by scripts/test-copyable-value-label.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private func expectEqual(_ actual: String?, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(String(describing: actual))")
    }
}

private let value = "hello world value"
private var clock = ProcessInfo.processInfo.systemUptime

private func mouse(
    _ type: NSEvent.EventType, x: CGFloat, clicks: Int, on label: NSView
) -> NSEvent {
    clock += 0.01
    return NSEvent.mouseEvent(
        with: type, location: label.convert(NSPoint(x: x, y: 10), to: nil),
        modifierFlags: [], timestamp: clock, windowNumber: label.window!.windowNumber,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

/// Posts the events, then dispatches the queue until it stays empty — the
/// editor's tracking loops take their drags and ups from the same queue.
private func dispatch(_ events: [NSEvent]) {
    for event in events { NSApp.postEvent(event, atStart: false) }
    while let event = NSApp.nextEvent(
        matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

private func doubleClick(_ label: NSView, x: CGFloat) {
    dispatch([
        mouse(.leftMouseDown, x: x, clicks: 1, on: label),
        mouse(.leftMouseUp, x: x, clicks: 1, on: label),
        mouse(.leftMouseDown, x: x, clicks: 2, on: label),
        mouse(.leftMouseUp, x: x, clicks: 2, on: label),
    ])
}

private func waitForRestore() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
}

// MARK: - Tests

func runTests() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    let label = CopyableValueLabel(labelWithString: value)
    label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .systemBlue
    label.isSelectable = true
    label.copyableValue = value
    label.frame = NSRect(x: 20, y: 80, width: 300, height: 20)
    window.contentView!.addSubview(label)
    window.orderFrontRegardless()
    window.makeKey()

    // --- A drag selects part of the value ---
    dispatch([
        mouse(.leftMouseDown, x: 2, clicks: 1, on: label),
        mouse(.leftMouseDragged, x: 40, clicks: 1, on: label),
        mouse(.leftMouseDragged, x: 60, clicks: 1, on: label),
        mouse(.leftMouseUp, x: 60, clicks: 1, on: label),
    ])
    guard let editor = label.currentEditor() as? NSTextView else {
        expectTrue(false, "a drag puts the field editor on the label")
        exit(1)
    }
    let range = editor.selectedRange()
    expectTrue(range.length > 0 && range.length < value.count,
               "a drag selects some of the characters, not all")

    NSPasteboard.general.clearContents()
    editor.copy(nil)
    expectEqual(NSPasteboard.general.string(forType: .string),
                String(value.dropFirst(range.location).prefix(range.length)),
                "Copy puts only the selected characters on the pasteboard")

    let storage = editor.textStorage!
    expectTrue(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue,
               "the selected value keeps its type colour")
    expectTrue((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true,
               "the selected value stays monospaced")

    // --- The editor's context menu still copies the whole value ---
    let menu = editor.menu(for: mouse(.rightMouseDown, x: 30, clicks: 1, on: label))
    expectEqual(menu?.items.first?.title, "Copy \"\(value)\"",
                "the editor's context menu offers the whole value first")

    // --- Double-click while the editor is on the label ---
    NSPasteboard.general.clearContents()
    doubleClick(label, x: 30)
    expectEqual(NSPasteboard.general.string(forType: .string), value,
                "a double-click on a selected value copies all of it")
    expectTrue(label.stringValue.contains("Copied"), "the copy shows its feedback")
    expectTrue(label.currentEditor() == nil, "the feedback ends the selection, so it shows")
    waitForRestore()
    expectEqual(label.stringValue, value, "the value comes back after the feedback")

    // --- Double-click on a label with no editor on it ---
    NSPasteboard.general.clearContents()
    clock += 1
    doubleClick(label, x: 30)
    expectEqual(NSPasteboard.general.string(forType: .string), value,
                "a double-click on an idle value copies all of it")

    // --- Two copies inside the feedback's 0.8 s ---
    doubleClick(label, x: 30)
    waitForRestore()
    expectEqual(label.stringValue, value,
                "a second copy during the feedback still restores the value")

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
