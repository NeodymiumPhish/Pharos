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

    /// Posted after any change, so every open grid rebuilds its tag map.
    static let didChange = Notification.Name("PharosTagStoreDidChange")

    /// Connection id → the index for that connection.
    private(set) var tagsByIdentity: [String: [String: RowTag]] = [:]

    /// The label palette. Global: a label carries no connection id.
    private(set) var labels: [TagLabel] = []

    private init() {}

    /// The index for one connection, or empty when nothing is loaded.
    func index(for connectionId: String) -> [String: RowTag] {
        tagsByIdentity[connectionId] ?? [:]
    }

    /// Load the palette and one connection's tags. Call on connect.
    ///
    /// Both FFI calls happen BEFORE either assignment, on purpose: a failure then
    /// leaves the previous state untouched rather than half-updated. An emptied
    /// index would silently mean "nothing is tagged", which reads as data loss.
    /// Do not reorder these lines.
    func load(connectionId: String) throws {
        // Already loaded: a tab switch must cost nothing. This is called from the
        // activeConnectionId didSet, which fires on tab focus as well as on connect,
        // so a plain switch between two connected connections must not re-read
        // SQLite or post a change that makes every grid rebuild its tag map.
        guard tagsByIdentity[connectionId] == nil else { return }
        let loadedLabels = try PharosCore.loadTagLabels()
        let tags = try PharosCore.loadRowTags(connectionId: connectionId)
        labels = loadedLabels
        tagsByIdentity[connectionId] = TagMatcher.index(tags)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Drop one connection's tags. Call on disconnect, so a reconnect reloads.
    func clear(connectionId: String) {
        tagsByIdentity.removeValue(forKey: connectionId)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
