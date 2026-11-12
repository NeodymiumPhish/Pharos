import Foundation

// MARK: - QueryVariableStore

/// The app's one in-memory copy of the app-wide query variables.
///
/// One app-wide list, edited in the Variable Manager window. Each variable is
/// global (the default) or linked to some connections; every run, EXPLAIN,
/// export and saved-query copy resolves its `{{name}}` tokens against the
/// variables its tab's connection can use (`available(for:)`,
/// `VariableScope`). There is no per-tab copy: a user who runs the same
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

    /// The variables a tab on `connectionId` can use: the global ones and
    /// those linked to it (`VariableScope`). Every run, EXPLAIN, export and
    /// copy resolves against this, never against the whole list.
    func available(for connectionId: String?) -> [QueryVariable] {
        VariableScope.available(variables, connectionId: connectionId)
    }

    /// The names a tab on `connectionId` highlights as defined.
    func definedNames(for connectionId: String?) -> Set<String> {
        Set(available(for: connectionId).map(\.name).filter { !$0.isEmpty })
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

    /// Read the list again because something other than this store changed
    /// it (File ▸ Import App Data…). Posts `didChange`, so the Variable
    /// Manager and every editor pick the new list up.
    func reload() throws {
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
            adoptNameStamps()
        } catch {
            Log.state.error("Failed to save query variables: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Take each variable's `nameSince` from the core, which stamps it on
    /// save. Nothing else is read back, so a field the user is typing in is
    /// left alone; and without this a variable made or renamed in this
    /// session would carry no stamp until the next launch, and read as one
    /// that has always had its name.
    private func adoptNameStamps() {
        guard let stored = try? PharosCore.loadQueryVariables() else {
            // Unknown: the name is treated as taken now, never as old.
            let now = Date()
            for i in variables.indices where variables[i].nameSince == nil { variables[i].nameSince = now }
            return
        }
        let stamps = Dictionary(stored.map { ($0.id, $0.nameSince) }, uniquingKeysWith: { first, _ in first })
        for i in variables.indices {
            if let stamp = stamps[variables[i].id] { variables[i].nameSince = stamp }
        }
    }

    /// Persist `variables`, then adopt them: for a caller with no field to
    /// keep and someone to tell when the write fails (`MCPToolHandlers`).
    func save(_ variables: [QueryVariable]) throws {
        try PharosCore.saveQueryVariables(variables)
        self.variables = variables
        adoptNameStamps()
        loaded = true
        postChange()
    }
}
