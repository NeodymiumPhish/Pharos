// Standalone test runner for TagNameSanitizer and the field rewrite that
// applies it. Compiled with the implementation by
// scripts/test-tag-name-sanitizer.sh.
//
// AppKit is imported for the second half only: the sanitiser itself is pure
// Foundation, and the field editor is what proves the caret survives a rewrite.
// The two sheets that call this (TagSheet, TagManageSheet) cannot be hosted
// here — both reach TagStore.shared, which is @MainActor and Keychain-bound
// through the FFI — so what is asserted is the shared helper they both call,
// exactly as they call it.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

/// A field hosted in a never-shown window, made first responder so that it has
/// a real field editor. Without the window there is no editor, and the caret
/// assertions would measure the `stringValue` fallback instead of the path the
/// sheets actually take.
private func editingField(_ text: String, caret: Int, length: Int = 0)
    -> (field: NSTextField, editor: NSText) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let field = NSTextField()
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    window.contentView?.addSubview(field)
    guard window.makeFirstResponder(field), let editor = field.currentEditor() else {
        print("FAIL the test field has no field editor — cannot measure the caret")
        exit(1)
    }
    editor.string = text
    editor.selectedRange = NSRange(location: caret, length: length)
    // The window is retained by the tuple's field through its superview chain
    // for as long as the caller holds either.
    objc_setAssociatedObject(field, "host", window, .OBJC_ASSOCIATION_RETAIN)
    return (field, editor)
}

/// A delegate that does exactly what both sheets do, so the "does this fight
/// ordinary typing / does it recurse" questions are answered against the real
/// notification rather than against a direct call.
private final class SanitizingDelegate: NSObject, NSTextFieldDelegate {
    private(set) var changeCount = 0
    func controlTextDidChange(_ obj: Notification) {
        changeCount += 1
        (obj.object as? NSTextField)?.sanitizeAsTagName()
    }
}

func runTests() {

    // MARK: - 1. The name that misrepresents itself

    do {
        // The reproduction: this pastes into the Add Tag sheet's Name field and
        // DISPLAYS as "safeexe.jpg". After sanitising there is no scalar left
        // that can reorder anything, so the name reads as what it holds.
        expectEqual(TagNameSanitizer.sanitized("safe\u{202E}gpj.exe"), "safegpj.exe",
                    "a right-to-left override cannot enter a name")
        expectEqual(TagNameSanitizer.sanitized("a\u{202A}b\u{202B}c\u{202C}d\u{202D}e"),
                    "abcde", "the whole embedding/override set is denied")
        expectEqual(TagNameSanitizer.sanitized("a\u{2066}b\u{2067}c\u{2068}d\u{2069}e"),
                    "abcde", "the isolate set is denied")
        expectEqual(TagNameSanitizer.sanitized("a\u{200E}b\u{200F}c\u{061C}d"), "abcd",
                    "the invisible bidi marks are denied, not just the overrides")
    }

    // MARK: - 2. Invisible characters, which make two names read alike

    do {
        expectEqual(TagNameSanitizer.sanitized("Case\u{200B}Alpha"), "CaseAlpha",
                    "a zero-width space cannot hide inside a name")
        expectEqual(TagNameSanitizer.sanitized("a\u{200C}b\u{200D}c\u{2060}d\u{FEFF}e"),
                    "abcde", "the rest of the zero-width family, and the BOM")
        // The point of the rule stated as the property it defends: two names
        // that LOOK the same must not be able to be different strings.
        let twins = ["Case Alpha", "Case\u{00A0}Alpha", "Case Alpha\u{200B}"]
            .map(TagNameSanitizer.sanitized)
        expectTrue(Set(twins).count == 1,
                   "three names that render identically become one string (\(Set(twins)))")
    }

    // MARK: - 3. Controls

    do {
        expectEqual(TagNameSanitizer.sanitized("a\u{0000}b\u{0007}c\u{001B}d"), "abcd",
                    "NUL, BEL and ESC are denied")
        expectEqual(TagNameSanitizer.sanitized("a\u{007F}b"), "ab", "DEL is denied")
        // The whitespace controls FOLD rather than vanish: a name pasted from a
        // cell can carry a newline, and "alphabeta" would be its own misreading.
        expectEqual(TagNameSanitizer.sanitized("alpha\nbeta"), "alpha beta",
                    "a newline folds to a space rather than joining two words")
        expectEqual(TagNameSanitizer.sanitized("a\tb\u{000B}c\u{000C}d\re"), "a b c d e",
                    "tab, VT, FF and CR fold the same way")
    }

    // MARK: - 4. Unusual spaces fold; they do not vanish

    do {
        // The decision this file records: NBSP and its relatives are folded to
        // a normal space, not removed. Removing would close a gap the author
        // can see and did intend.
        expectEqual(TagNameSanitizer.sanitized("Case\u{00A0}Alpha"), "Case Alpha",
                    "NBSP becomes a space, so the name keeps the gap it shows")
        expectEqual(TagNameSanitizer.sanitized("a\u{2003}b\u{202F}c\u{205F}d\u{3000}e"),
                    "a b c d e",
                    "em space, narrow NBSP, medium mathematical space and the ideographic space fold")
        expectEqual(TagNameSanitizer.sanitized("a\u{2000}b\u{200A}c"), "a b c",
                    "both ends of the U+2000…U+200A block fold")
    }

    // MARK: - 5. What must NOT be touched

    do {
        // A sanitiser that trimmed or collapsed would fight ordinary typing:
        // the space you just typed would disappear from under the caret.
        expectEqual(TagNameSanitizer.sanitized("  Case  Alpha  "), "  Case  Alpha  ",
                    "no trimming and no collapsing — both sheets trim at save instead")
        expectEqual(TagNameSanitizer.sanitized("café ☕ 日本 — Ω"), "café ☕ 日本 — Ω",
                    "accents, emoji, CJK, an em dash and Greek are ordinary text")
        expectEqual(TagNameSanitizer.sanitized("APT-41 / \"quoted\" <b> 'x'"),
                    "APT-41 / \"quoted\" <b> 'x'",
                    "punctuation a case name really carries is left alone")
        expectEqual(TagNameSanitizer.sanitized("𝔸 \u{1F600}"), "𝔸 \u{1F600}",
                    "astral scalars survive — the scan is per scalar, not per UTF-16 unit")
        expectTrue(!TagNameSanitizer.needsSanitizing("Case Alpha"),
                   "an ordinary name is reported as needing nothing, so the field is never rewritten")
        expectTrue(TagNameSanitizer.needsSanitizing("Case\u{202E}Alpha"),
                   "and a deceptive one is reported as needing the rewrite")
    }

    // MARK: - 6. Idempotence

    do {
        // The change handler rewrites the field, which can raise the change
        // notification again. A second pass must be a no-op or that is a loop.
        let once = TagNameSanitizer.sanitized("safe\u{202E}gpj\u{00A0}.exe\u{200B}")
        expectEqual(TagNameSanitizer.sanitized(once), once,
                    "sanitising twice is sanitising once")
        expectTrue(!TagNameSanitizer.needsSanitizing(once),
                   "so the guard stops the second pass before it touches the editor")
        expectEqual(TagNameSanitizer.sanitized(""), "", "an empty name is left empty")
        expectEqual(TagNameSanitizer.sanitized("\u{202E}\u{200B}"), "",
                    "a name made only of deceptive scalars sanitises away to nothing")
    }

    // MARK: - 7. The caret arithmetic

    do {
        // Offsets are UTF-16, the unit NSTextView.selectedRange speaks.
        let raw = "safe\u{202E}gpj.exe"
        expectEqual(TagNameSanitizer.sanitizedCaret(in: raw, at: 0), 0,
                    "a caret at the start stays at the start")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: raw, at: 4), 4,
                    "a caret before the removed scalar does not move")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: raw, at: 5), 4,
                    "a caret just after it moves back by exactly one")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: raw, at: raw.utf16.count),
                    raw.utf16.count - 1,
                    "and a caret at the end lands at the end of the shorter name")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: "a\u{00A0}b", at: 3), 3,
                    "a folded scalar keeps its width, so the caret does not move")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: "\u{1F600}\u{202E}x", at: 3), 2,
                    "an astral scalar counts as its two UTF-16 units")
        expectEqual(TagNameSanitizer.sanitizedCaret(in: "ab", at: 99), 2,
                    "an offset past the end clamps rather than trapping")
    }

    // MARK: - 8. The field rewrite, through a real field editor

    do {
        // The paste in the bug report, made in the middle of a name the analyst
        // had already typed. The caret must stay where the pasted text ended.
        let (field, editor) = editingField("Case safe\u{202E}gpj.exe Alpha", caret: 21)
        field.sanitizeAsTagName()
        expectEqual(editor.string, "Case safegpj.exe Alpha",
                    "the field itself no longer holds the override")
        expectEqual(field.stringValue, "Case safegpj.exe Alpha",
                    "and the value the sheet reads back agrees with what is drawn")
        expectEqual(editor.selectedRange.location, 20,
                    "the caret stays after the pasted text, not thrown to the end")
        expectEqual(editor.selectedRange.length, 0, "and it is still a caret, not a selection")
    }

    do {
        // A rewrite that lands while text is selected must not leave the
        // selection covering characters that are gone.
        let (field, editor) = editingField("a\u{202E}bcdef", caret: 2, length: 3)
        field.sanitizeAsTagName()
        expectEqual(editor.string, "abcdef", "the override goes")
        expectEqual(editor.selectedRange.location, 1, "the selection start follows the text")
        expectEqual(editor.selectedRange.length, 3, "and its length still covers \"bcd\"")
    }

    do {
        // Ordinary typing must be left completely alone — including the caret,
        // which a blind rewrite would move even when the text did not change.
        let (field, editor) = editingField("Case Alpha", caret: 4)
        field.sanitizeAsTagName()
        expectEqual(editor.string, "Case Alpha", "an ordinary name is untouched")
        expectEqual(editor.selectedRange.location, 4,
                    "and the caret is left exactly where it was")
    }

    do {
        // The reason the guard is not merely an optimisation: an input method
        // composes into MARKED text, and assigning the editor's string unmarks
        // it — measured, so a rewrite on every keystroke would cut a Japanese
        // or Chinese name off mid-syllable. Nothing here needs sanitising, so
        // nothing may touch the editor.
        let (field, editor) = editingField("Case ", caret: 5)
        guard let textView = editor as? NSTextView else {
            failures += 1
            print("FAIL the field editor is not an NSTextView — cannot mark text")
            print("\n\(failures) failure(s).")
            exit(1)
        }
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: textView.selectedRange)
        expectTrue(textView.hasMarkedText(), "the fixture really is mid-composition")
        field.sanitizeAsTagName()
        expectTrue(textView.hasMarkedText(),
                   "an ordinary keystroke leaves the editor alone, so a composition survives")
    }

    // An active IME composition must survive the sanitiser: the rewrite runs
    // when the composition commits, not during it. (Rewriting editor.string
    // mid-composition unmarks and destroys the user's marked text.)
    do {
        let (field, editor) = editingField("", caret: 0)
        guard let textView = editor as? NSTextView else {
            failures += 1
            print("FAIL the field editor is not an NSTextView — cannot mark text")
            print("\n\(failures) failure(s).")
            exit(1)
        }
        textView.setMarkedText("safe\u{202E}",
                               selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        field.sanitizeAsTagName()
        expectEqual(textView.hasMarkedText(), true,
                    "sanitising during composition leaves the marked text alone")
        expectEqual(editor.string, "safe\u{202E}",
                    "the composed text is not rewritten while marked")
        textView.unmarkText()
        field.sanitizeAsTagName()
        expectEqual(editor.string, "safe",
                    "the rewrite runs once the composition commits")
    }

    do {
        // No editor: the path a call from outside an edit session takes. The
        // Manage sheet loads a stored name into the field this way.
        let plain = NSTextField()
        plain.stringValue = "old\u{202E}name"
        plain.sanitizeAsTagName()
        expectEqual(plain.stringValue, "oldname",
                    "a field with no field editor is still cleaned")
    }

    // MARK: - 9. Wired the way the sheets wire it

    do {
        // Driven through the REAL notification, with a delegate shaped exactly
        // like the sheets'. This is what answers "does rewriting the editor
        // inside controlTextDidChange loop, and does typing survive it".
        let delegate = SanitizingDelegate()
        let (field, editor) = editingField("", caret: 0)
        field.delegate = delegate
        guard let textView = editor as? NSTextView else {
            failures += 1
            print("FAIL the field editor is not an NSTextView — cannot type into it")
            print("\n\(failures) failure(s).")
            exit(1)
        }
        for piece in ["Case", " ", "safe\u{202E}gpj.exe"] {
            textView.insertText(piece, replacementRange: textView.selectedRange)
        }
        expectEqual(editor.string, "Case safegpj.exe",
                    "typing then pasting through the delegate leaves a name that reads as itself")
        expectEqual(editor.selectedRange.location, 16,
                    "with the caret at the end of what was typed")
        expectTrue(delegate.changeCount >= 3,
                   "the change notification fired for each edit (\(delegate.changeCount))")
        expectTrue(delegate.changeCount < 20,
                   "and the rewrite did not feed itself a cascade of further changes (\(delegate.changeCount))")
    }

    // MARK: - 10. Parity with DisplayEscape's widened scalar set

    do {
        // Scalars added by the hostile-text hardening phase. Line and paragraph
        // separators and NEL fold like the C0 whitespace (joining alpha to beta
        // would be its own misreading); the ogham space folds like the other
        // unusual spaces; the invisible scalars (the rest of C1, and the
        // Mongolian vowel separator) are removed.
        expectEqual(TagNameSanitizer.sanitized("one\u{2028}two"), "one two",
                    "line separator folds to a space")
        expectEqual(TagNameSanitizer.sanitized("one\u{2029}two"), "one two",
                    "paragraph separator folds to a space")
        expectEqual(TagNameSanitizer.sanitized("one\u{0085}two"), "one two",
                    "NEL folds to a space")
        expectEqual(TagNameSanitizer.sanitized("a\u{009B}b"), "ab",
                    "a C1 control is removed")
        expectEqual(TagNameSanitizer.sanitized("a\u{1680}b"), "a b",
                    "ogham space mark folds to a space")
        expectEqual(TagNameSanitizer.sanitized("a\u{180E}b"), "ab",
                    "Mongolian vowel separator is removed")
    }

    if failures == 0 {
        print("\nAll TagNameSanitizer tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
