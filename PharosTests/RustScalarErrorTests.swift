// Standalone test runner for RustScalarError. Not part of the app target —
// compiled together with the implementation by scripts/test-rust-scalar-error.sh.
import Foundation

var failures = 0

func expectNil(_ actual: String?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: nil\n  actual:   \(actual!.debugDescription)")
    }
}

func expectMessage(_ actual: String?, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(String(describing: actual))")
    }
}

func expectPrefix(_ text: String, _ expected: Bool, _ name: String) {
    let actual = text.withCString { RustScalarError.beginsWithErrorKey($0) }
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // MARK: - The scalar successes the FFI actually returns

    // These are the only three shapes a scalar-returning pharos_* function gives
    // on success. Each one must read as "no error", or a delete that worked would
    // report a failure.
    expectNil(RustScalarError.message(in: "true"), "bare true is not an error")
    expectNil(RustScalarError.message(in: "false"), "bare false is not an error")
    expectNil(RustScalarError.message(in: "0"), "zero count is not an error")
    expectNil(RustScalarError.message(in: "42"), "decimal count is not an error")

    // MARK: - The failure object

    expectMessage(
        RustScalarError.message(in: #"{"error": "database is locked"}"#),
        "database is locked",
        "reads the message out of the failure object"
    )

    // ffi_sync! writes this one itself when the body panics, with no space after
    // the colon. Both spellings must be found.
    expectMessage(
        RustScalarError.message(in: #"{"error":"internal panic"}"#),
        "internal panic",
        "finds the panic object the ffi_sync! macro writes"
    )

    // serde_json escapes the inner quotes; the message must come back unescaped.
    expectMessage(
        RustScalarError.message(in: #"{"error": "no such column: \"foo\""}"#),
        #"no such column: "foo""#,
        "unescapes a quoted identifier inside the message"
    )

    expectMessage(
        RustScalarError.message(in: #"{"error": "près de la ligne 3 — ✓"}"#),
        "près de la ligne 3 — ✓",
        "carries non-ASCII through unchanged"
    )

    // MARK: - Objects that are not failures

    // A scalar wrapper should never see this, but returning the whole blob as a
    // message would be worse than returning nil: the caller then reports a
    // decode complaint that names the real problem.
    expectNil(
        RustScalarError.message(in: #"{"id": "abc", "name": "weekly report"}"#),
        "an object with no error key is not an error"
    )

    // This is the rule that lets a JSON-returning wrapper share the check.
    // ValidationResult carries an `error` field of its own, so a result object
    // must not be read as a failure just because it has that key. The failure
    // object has exactly one.
    expectNil(
        RustScalarError.message(in: #"{"valid": false, "error": "syntax error at or near \"slect\""}"#),
        "a result object that merely has an error field is not a failure"
    )
    expectNil(
        RustScalarError.message(in: #"{"error": "boom", "code": 42}"#),
        "a two-key object is not the failure object"
    )

    // The FFI always writes a string. A non-string value is not a message, so it
    // must not be forced into one.
    expectNil(
        RustScalarError.message(in: #"{"error": 42}"#),
        "a non-string error value is not a message"
    )
    expectNil(
        RustScalarError.message(in: #"{"error": null}"#),
        "a null error value is not a message"
    )

    // MARK: - Text that only looks like the failure object

    // A truncated read must not throw a made-up error. Nil sends the caller down
    // its own "unexpected result" path, which names the text it got.
    expectNil(RustScalarError.message(in: #"{"error": "cut off"#), "malformed JSON is not an error")
    expectNil(RustScalarError.message(in: "{"), "a lone brace is not an error")
    expectNil(RustScalarError.message(in: ""), "empty text is not an error")

    // A JSON array also starts with a bracket, not a brace, so the prefix test
    // already refuses it before the parse.
    expectNil(RustScalarError.message(in: #"["error"]"#), "a JSON array is not an error")

    // The prefix test is deliberate: a value that merely contains the object is
    // not the object. The FFI never pads its returns.
    expectNil(
        RustScalarError.message(in: #" {"error": "leading space"}"#),
        "the object must start the text"
    )

    // MARK: - The byte-level pre-check used by the JSON path

    // `decodeNoCopy` calls this before it builds any Swift string, so a large
    // successful load pays nothing. It must agree with `message(in:)` on both
    // spellings the core actually writes.
    expectPrefix(#"{"error":"database is locked"}"#, true, "compact object, as serde_json writes it")
    expectPrefix(#"{"error": "database is locked"}"#, true, "a space after the colon still matches")

    // A result object is ruled out on the first byte or the key.
    expectPrefix(#"{"id": "abc"}"#, false, "a result object does not match")
    expectPrefix(#"[{"id": "abc"}]"#, false, "an array does not match")
    expectPrefix("true", false, "a scalar does not match")

    // Reading must stop at the NUL, not run past a short buffer.
    expectPrefix("", false, "an empty buffer does not match and does not overrun")
    expectPrefix("{", false, "a lone brace does not match and does not overrun")
    expectPrefix(#"{"err"#, false, "a buffer shorter than the prefix does not overrun")

    // A near miss must not match: the key is exactly `error`.
    expectPrefix(#"{"errors":["x"]}"#, false, "the key must be error, not errors")
    expectPrefix(#"{ "error":"x"}"#, false, "a space before the key does not match")

    // Every text that message(in:) calls a failure must also pass the pre-check,
    // or the JSON path would skip a real failure that the scalar path catches.
    for text in [#"{"error":"internal panic"}"#, #"{"error": "près de la ligne 3"}"#] {
        let found = RustScalarError.message(in: text) != nil
        let prefixed = text.withCString { RustScalarError.beginsWithErrorKey($0) }
        if found && !prefixed {
            failures += 1
            print("FAIL pre-check disagrees with message(in:) for \(text.debugDescription)")
        } else {
            print("PASS pre-check agrees with message(in:) for \(text.debugDescription)")
        }
    }

    if failures == 0 {
        print("\nAll RustScalarError tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
