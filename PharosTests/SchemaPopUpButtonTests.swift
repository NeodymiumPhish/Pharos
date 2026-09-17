// Standalone test runner for SchemaPopUpButton — the toolbar's schema
// pull-down. It opens a popover instead of its menu, so it has to fake the
// pressed look AppKit gives a pull-down while its menu is up.
import AppKit

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
    window.contentView = root
    let button = SchemaPopUpButton(frame: NSRect(x: 10, y: 10, width: 150, height: 30), pullsDown: true)
    button.bezelStyle = .toolbar
    button.addItem(withTitle: "All Schemas")
    root.addSubview(button)

    var activations = 0
    button.onActivate = { _ in activations += 1 }

    // A click activates through the hook and never opens the native menu.
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 25), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
    button.mouseDown(with: click)
    expectTrue(activations == 1, "a click calls onActivate once")
    expectTrue(button.cell?.isHighlighted == false, "the click alone does not leave the cell highlighted")

    // While the owner says the popover is up, the button draws pressed.
    button.isPresenting = true
    expectTrue(button.cell?.isHighlighted == true, "isPresenting highlights the cell (the pressed look)")
    button.isPresenting = false
    expectTrue(button.cell?.isHighlighted == false, "clearing isPresenting releases the highlight")

    // Space and Return open it too; an unrelated key does not.
    func key(_ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }
    button.keyDown(with: key(" "))
    expectTrue(activations == 2, "Space activates")
    button.keyDown(with: key("\r"))
    expectTrue(activations == 3, "Return activates")
    button.keyDown(with: key("x"))
    expectTrue(activations == 3, "an ordinary key does not activate")

    // Disabled: the hook is not called.
    button.isEnabled = false
    button.mouseDown(with: click)
    expectTrue(activations == 3, "a disabled button ignores the click")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
