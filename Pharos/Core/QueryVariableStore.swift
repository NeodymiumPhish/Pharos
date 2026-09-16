import Foundation

// MARK: - QueryVariableStore

/// The app's one in-memory copy of the app-wide query variables.
///
/// Variables are GLOBAL: every run, EXPLAIN, export and saved-query copy in
/// every window resolves its `{{name}}` tokens against this one list, and the
/// Variables navigator in every sidebar edits it. There is deliberately no
/// per-tab or per-connection copy any more — a user who runs the same
/// parameterised queries against several databases keeps the values once.
///
/// `@MainActor` because every reader is a view controller and every write
/// follows a user action. The FFI calls are synchronous and local (SQLite), so
/// they need not leave the main thread — see `PharosCore+QueryVariables.swift`.
@MainActor
final class QueryVariableStore {

    static let shared = QueryVariableStore()

    /// Posted after any change to the cached list, including the initial load.
    /// Always global and always a synchronous main-thread post. The sidebar that
    /// ORIGINATED a change receives it too; it compares against `variables`
    /// before adopting it, so a field being typed in is never reset.
    static let didChange = Notification.Name("PharosQueryVariablesDidChange")

    private init() {}

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private(set) var variables: [QueryVariable] = []

    /// The names the editor should highlight: every non-empty name in the list.
    var definedNames: Set<String> {
        Set(variables.map(\.name).filter { !$0.isEmpty })
    }

    private var loaded = false

    /// Read the list once. Later calls cost nothing. Posts `didChange` after a
    /// load so a sidebar built before the load still fills in.
    func loadIfNeeded() throws {
        guard !loaded else { return }
        variables = try PharosCore.loadQueryVariables()
        loaded = true
        postChange()
    }

    /// Adopt `variables` as the whole list, then persist it.
    ///
    /// The in-memory assignment and the post come FIRST, the write second: the
    /// panel that called this already holds the edited array, so a failed
    /// write must not revert the field the user is typing in. The failure is
    /// logged; the next edit retries the whole list, because every save writes
    /// the whole list.
    func replace(_ variables: [QueryVariable]) {
        self.variables = variables
        loaded = true
        postChange()
        do {
            try PharosCore.saveQueryVariables(variables)
        } catch {
            Log.state.error("Failed to save query variables: \(error.localizedDescription, privacy: .public)")
        }
    }
}
