import Foundation

// MARK: - TagManagerCommitting

/// The one store capability the Tag Manager needs.
///
/// The manager commits through this rather than through the whole store, so its
/// standalone harness can compile the sheet without `TagStore` — which is
/// `@MainActor` and reaches the macOS Keychain through the FFI, and would hang a
/// headless run. Exactly the shape `TagRuleRemoving` already uses, and for
/// exactly the same reason.
///
/// The conformance lives in `TagStore.swift`, so a change to this signature
/// fails the APP build. A test double declared on the far side could drift from
/// the real store in silence, which is the failure this arrangement exists to
/// prevent.
///
/// Deliberately nonisolated: the harness conforms without `@MainActor`. Every
/// real caller is a view-controller action, so every real call is already on the
/// main thread.
protocol TagManagerCommitting {
    /// Apply every command, in order, as one logical save.
    ///
    /// Order matters: `TagManagerModel.commits()` emits deletes before adds,
    /// because the unique index on `(tag_id, tuple_key)` would otherwise refuse
    /// a rebuilt rule whose key did not change.
    func apply(_ commits: [TagManagerCommit]) throws
}
