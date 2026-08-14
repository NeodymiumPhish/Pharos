// MARK: - TagTupleRemoving

/// The one store capability `TagRemovalSheet` needs.
///
/// It lives in its own file, depending on nothing, because the two sides of
/// this seam are compiled apart by two different standalone harnesses and
/// neither may drag in the other:
///
/// - `scripts/test-tag-removal-sheet.sh` compiles the SHEET without the store.
///   `TagStore` is `@MainActor` (which `PharosTests/main.swift` cannot call
///   into from nonisolated top-level scope) and reaches the Keychain through
///   the FFI, which would hang a headless run. The test file supplies its own
///   conformer instead.
/// - `scripts/test-tag-store.sh` compiles the STORE without the sheet, so it
///   must not need `TagRemovalSheet.swift` — an AppKit view controller — just
///   to see the protocol its conformance names.
///
/// Declaring it inside either file breaks the other suite's compile. That is
/// not hypothetical: it was declared in `TagRemovalSheet.swift` when the
/// conformance was added to `TagStore.swift`, and `test-tag-store.sh` stopped
/// building. The break went unnoticed because that suite needs a Keychain
/// prompt and so is never run headlessly.
///
/// `TagStore` conforms in `TagStore.swift`, so a change to
/// `removeTuples(ids:)`'s shape breaks the APP BUILD rather than quietly
/// leaving a test double behind on the far side.
protocol TagTupleRemoving {
    func removeTuples(ids: [String]) throws
}
