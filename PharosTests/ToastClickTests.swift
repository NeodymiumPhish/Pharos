// Standalone test runner for the Toast click handler. Uses real AppKit: the
// toast is hosted in a headless, never-shown NSWindow and clicked through
// mouseDown, the same entry point a real click uses.
// Compiled with Toast.swift by scripts/test-toast-click.sh.
import AppKit

private var failures = 0

private func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectString(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name) [\(actual ?? "nil")]") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")")
    }
}

private func makeHost() -> NSView {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = host
    return host
}

private func click(_ toast: ToastView) {
    let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: toast.window?.windowNumber ?? 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!
    toast.mouseDown(with: event)
}

func runTests() {
    var clicks = 0
    let host = makeHost()
    Toast.show(in: host, message: "Query 1 · boom", style: .error, duration: 60) { clicks += 1 }
    host.layoutSubtreeIfNeeded()

    guard let toast = host.subviews.compactMap({ $0 as? ToastView }).first else {
        print("FAIL the toast was not added to the host")
        exit(1)
    }
    expectTrue(toast.hasClickHandler, "a toast with a handler reports that it is clickable")

    click(toast)
    expectInt(clicks, 1, "a click runs the handler")
    expectTrue(toast.isFadingOut, "a click starts the fade")

    click(toast)
    expectInt(clicks, 1, "a second click on a fading toast does nothing")

    let plainHost = makeHost()
    Toast.show(in: plainHost, message: "no handler", style: .info, duration: 60)
    guard let plain = plainHost.subviews.compactMap({ $0 as? ToastView }).first else {
        print("FAIL the second toast was not added to the host")
        exit(1)
    }
    expectTrue(!plain.hasClickHandler, "a toast with no handler is not clickable")
    click(plain)
    expectTrue(!plain.isFadingOut, "a click on a toast with no handler changes nothing")

    // MARK: Accessibility
    //
    // A toast is never focused and is gone in two seconds, so what it says to a
    // screen reader is all it says at all. The SEVERITY has to be in the words:
    // it is otherwise a coloured stripe and an icon.
    let axHost = makeHost()
    Toast.show(in: axHost, message: "Query 3 failed", style: .error, duration: 60) { }
    Toast.show(in: axHost, message: "Copied 4 rows", style: .success, duration: 60)
    let toasts = axHost.subviews.compactMap { $0 as? ToastView }
    expectInt(toasts.count, 2, "both toasts are in the host")

    expectTrue(toasts[0].isAccessibilityElement(), "a toast is an accessibility element")
    expectTrue(toasts[0].accessibilityRole() == .staticText, "a toast is static text")
    expectString(toasts[0].accessibilityLabel(), "Error: Query 3 failed",
                 "the label carries the severity the stripe and icon carry")
    expectString(toasts[1].accessibilityLabel(), "Success: Copied 4 rows",
                 "a success toast says success")
    expectString(toasts[0].accessibilityHelp(), "Click to open",
                 "a clickable toast says it can be clicked")
    expectString(toasts[1].accessibilityHelp(), nil,
                 "a toast with no handler offers no click")

    // MARK: Escape
    //
    // `ResultsGridVC.cancelOperation` calls this before it closes the find bar,
    // so Escape takes the newest toast first. The search descends the tree: the
    // view that owns Escape is not the view a toast was raised in.
    expectTrue(Toast.dismissNewest(in: axHost), "Escape finds a toast to dismiss")
    expectTrue(toasts[1].isFadingOut, "the NEWEST toast is the one dismissed")
    expectTrue(!toasts[0].isFadingOut, "the older toast stays")
    expectTrue(Toast.dismissNewest(in: axHost), "Escape then takes the next one")
    expectTrue(toasts[0].isFadingOut, "which is the older toast")
    expectTrue(!Toast.dismissNewest(in: axHost),
               "with every toast already fading, Escape reports nothing to dismiss "
               + "— so the key falls through to the find bar")

    let emptyHost = makeHost()
    expectTrue(!Toast.dismissNewest(in: emptyHost), "a host with no toast reports nothing")

    // The real pairing: `ResultsGridVC` handles Escape but the toast was raised
    // in `ContentViewController`'s view, several levels down from the window.
    let outer = makeHost()
    let inner = NSView(frame: outer.bounds)
    outer.addSubview(inner)
    Toast.show(in: inner, message: "buried", style: .info, duration: 60)
    expectTrue(Toast.dismissNewest(in: outer), "Escape reaches a toast raised in a descendant view")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
