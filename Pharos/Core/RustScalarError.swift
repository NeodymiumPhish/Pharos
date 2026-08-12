import Foundation

// MARK: - RustScalarError

/// Reads the failure side of the sync FFI's single return channel.
///
/// Every `pharos_*` function built on the `ffi_sync!` macro returns ONE C-string
/// for both outcomes: the result on success, and the object `{"error": "..."}` on
/// failure. A scalar-returning function therefore answers `true`, `false` or a
/// decimal when it worked, and a JSON object when it did not. Testing the success
/// text alone (`== "true"`) turns a real failure — a locked database, a SQLite
/// error — into a negative answer that reads as "nothing happened".
///
/// The macro also converts a panic into `{"error":"internal panic"}`, so the check
/// applies even to a function whose command layer cannot fail.
///
/// This type holds no AppKit and no `CPharosCore`, which keeps it compilable on
/// its own — see `scripts/test-rust-scalar-error.sh`. The FFI helpers in
/// `PharosCore.swift` are the only callers.
enum RustScalarError {

    /// The core's message when `text` is the failure object, otherwise nil.
    ///
    /// The object must hold EXACTLY the one key `error`, carrying a string. Every
    /// failure in `pharos-core/src/ffi/` is built as `json!({"error": ...})`, or is
    /// the macro's own `{"error":"internal panic"}`, so one key is the whole shape.
    ///
    /// That strictness is what lets a JSON-returning wrapper use this check as
    /// well. A result object may legitimately carry an `error` field of its own —
    /// `ValidationResult` does — but it carries other fields with it, so it can
    /// never be mistaken for a failure. If the core ever adds a second field to
    /// its failure object, this check stops finding it: the pinned shape in
    /// `PharosTests/RustScalarErrorTests.swift` is what says so out loud.
    static func message(in text: String) -> String? {
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1
        else { return nil }
        return object["error"] as? String
    }

    /// The bytes every failure object opens with. serde_json writes compact output
    /// — no space before the colon, and the single key first — so the whole
    /// failure channel starts with these nine bytes and nothing else does.
    private static let errorKeyPrefix = Array(#"{"error":"#.utf8)

    /// True when a C-string buffer opens with the failure object's key.
    ///
    /// This exists so that a JSON wrapper can rule out a failure WITHOUT building
    /// a Swift string first. `PharosCore.decodeNoCopy` decodes straight from the
    /// C buffer to avoid two full-JSON copies per call, and a result set can be
    /// large; paying a full allocation on every successful load just to look for
    /// an error object would undo that. A buffer that passes this test is short
    /// and about to throw anyway, so `message(in:)` may allocate freely.
    ///
    /// Reading stops at the NUL, so a buffer shorter than the prefix is safe.
    static func beginsWithErrorKey(_ ptr: UnsafePointer<CChar>) -> Bool {
        for (offset, expected) in errorKeyPrefix.enumerated() {
            let byte = ptr[offset]
            if byte == 0 || UInt8(bitPattern: byte) != expected { return false }
        }
        return true
    }
}
