// Standalone tests for AuthoredLabelTextField. Drives a REAL field editor in a
// headless window: the whole point of the type is that it is its own delegate,
// and a test that called the sanitiser directly would prove nothing about the
// wiring.
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

/// A field hosted in a never-shown window, focused so it has a field editor.
private func hostedField() -> (NSWindow, AuthoredLabelTextField, NSText) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let field = AuthoredLabelTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    window.contentView?.addSubview(field)
    window.makeFirstResponder(field)
    guard let editor = field.currentEditor() else {
        print("FAIL the hosted field has a field editor")
        print("\n1 failure(s).")
        exit(1)
    }
    return (window, field, editor)
}

func runTests() {
    _ = NSApplication.shared

    // It is its own delegate, and that is the mechanism — not a detail.
    do {
        let (_, field, _) = hostedField()
        expectTrue((field.delegate as AnyObject?) === field,
                   "the field is its own delegate, so no caller has to wire one")
    }

    // Ordinary typing is untouched, and the caret is not disturbed.
    do {
        let (_, field, editor) = hostedField()
        editor.insertText("case_alpha")
        expectEqual(field.stringValue, "case_alpha", "ordinary typing is left alone")
        expectEqual(editor.selectedRange.location, 10, "the caret sits after what was typed")
    }

    // A pasted hostile scalar never survives in the field.
    do {
        let (_, field, editor) = hostedField()
        editor.insertText("safe\u{202E}gpj.exe")
        expectTrue(!field.stringValue.unicodeScalars.contains("\u{202E}"),
                   "a pasted bidi override is removed as it arrives")
        expectEqual(field.stringValue, "safegpj.exe",
                    "what is left is exactly the visible text")
    }

    // An unusual space folds rather than vanishing, so the gap the author
    // meant is still there.
    do {
        let (_, field, editor) = hostedField()
        editor.insertText("case\u{00A0}alpha")
        expectEqual(field.stringValue, "case alpha",
                    "a non-breaking space folds to a plain one")
    }

    // Sanitising mid-string keeps the caret in the text, not at the end.
    do {
        let (_, field, editor) = hostedField()
        editor.insertText("abc")
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.insertText("\u{200B}")
        expectEqual(field.stringValue, "abc", "the zero-width paste leaves no trace")
        expectTrue(editor.selectedRange.location <= 3,
                   "the caret stays inside the text rather than jumping to the end")
    }

    // The no-editor path: a seeded default must not hold a hostile name either.
    do {
        let field = AuthoredLabelTextField(frame: .zero)
        field.stringValue = "seed\u{200B}ed"
        field.sanitizeAsAuthoredLabel()
        expectEqual(field.stringValue, "seeded",
                    "a seeded value can be sanitised with no field editor present")
    }

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
