import Foundation

// MARK: - TagStore

/// The in-memory index of every row tag for one connection.
///
/// Tags are per connection, so the store is keyed by connection id and a
/// disconnect drops that connection's entry. The index itself is built by
/// `TagMatcher.index(_:)` — one entry per stored key, so a strong tag appears
/// twice.
///
/// `@MainActor` because every reader is a view controller and every write follows
/// a user action. The FFI calls it makes are synchronous and local (SQLite), so
/// they do not need to leave the main thread — see `PharosCore+RowTags.swift`.
@MainActor
final class TagStore {

    static let shared = TagStore()

    /// Posted after a change to the cached tags.
    ///
    /// `userInfo[connectionIdKey]` names the affected connection. An absent key means
    /// a global change — Phase 4's palette edits.
    ///
    /// Two facts Task 8's observer depends on. `TagStore` is `@MainActor`, so every
    /// post is a main-thread post. And the post from `reload` runs inside the
    /// `activeConnectionId` didSet, which is a `@Published` property's didSet — so an
    /// observer runs on the connection switch's own call stack. Keep the observer
    /// cheap, and do not write `AppStateManager` state from it.
    static let didChange = Notification.Name("PharosTagStoreDidChange")
    static let connectionIdKey = "connectionId"

    /// Connection id → the index for that connection.
    private(set) var tagsByIdentity: [String: [String: RowTag]] = [:]

    /// The label palette. Global: a label carries no connection id.
    ///
    /// The cache guard in `loadIfNeeded` is per connection, but this list is not: a
    /// label created after the last UNCACHED load will not appear here until some
    /// connection loads for the first time (or `reload` runs). Phase 2 has no write
    /// surface, so this is latent, not live — Phase 4 adds one, and `reload` is the
    /// way it keeps this current.
    private(set) var labels: [TagLabel] = []

    private init() {}

    /// The index for one connection, or empty when nothing is loaded.
    ///
    /// An empty result does not distinguish "never loaded" from "loaded and truly has
    /// no tags" — both read `[:]`. That is fine for a reader that also watches
    /// `didChange`, which covers a tag arriving late; it would not be fine for a
    /// caller that treats an empty index as a settled answer.
    func index(for connectionId: String) -> [String: RowTag] {
        tagsByIdentity[connectionId] ?? [:]
    }

    /// Load this connection's tags if they are not cached yet.
    ///
    /// Called from the `activeConnectionId` didSet, which fires on tab focus as well
    /// as on connect, so a switch between two connected connections must cost
    /// nothing. Use `reload` after a write.
    func loadIfNeeded(connectionId: String) throws {
        guard tagsByIdentity[connectionId] == nil else { return }
        try reload(connectionId: connectionId)
    }

    /// Read this connection's tags and the palette from SQLite, replacing whatever is
    /// cached. This is the write path's refresh — Phase 3 calls it after a tag write.
    ///
    /// Both FFI calls happen before either assignment, so a failure part-way leaves
    /// the previous state untouched rather than half-updated.
    func reload(connectionId: String) throws {
        let loadedLabels = try PharosCore.loadTagLabels()
        let tags = try PharosCore.loadRowTags(connectionId: connectionId)
        labels = loadedLabels
        tagsByIdentity[connectionId] = TagMatcher.index(tags)
        post(connectionId: connectionId)
    }

    /// Drop one connection's tags, so the next activation reads SQLite fresh.
    func clear(connectionId: String) {
        guard tagsByIdentity.removeValue(forKey: connectionId) != nil else { return }
        post(connectionId: connectionId)
    }

    private func post(connectionId: String?) {
        NotificationCenter.default.post(
            name: Self.didChange, object: nil,
            userInfo: connectionId.map { [Self.connectionIdKey: $0] })
    }
}
