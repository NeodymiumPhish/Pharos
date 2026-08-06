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

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
