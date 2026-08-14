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

    // MARK: - Mutations

    /// UserDefaults key for the last label ⌘L applies.
    static let lastUsedLabelKey = "PharosLastTagLabel"

    /// The id can name a label that no longer exists; consumers must validate
    /// it against `labels` before use.
    var lastUsedLabelId: String? {
        get { UserDefaults.standard.string(forKey: Self.lastUsedLabelKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastUsedLabelKey) }
    }

    /// The label ⌘L will actually use: the stored id when it still names a
    /// label, else the first label, else nil. The one resolution both the
    /// validator's title and the action must share — a raw read can name a
    /// deleted label and make the two disagree.
    var effectiveLastLabelId: String? {
        lastUsedLabelId.flatMap { id in labels.first { $0.id == id }?.id }
            ?? labels.first?.id
    }

    /// Write one tag and refresh that connection's index. The write is
    /// key-set-aware in the core (it replaces any tag matching ANY key), so
    /// the reload — not a hand-applied delta — is what keeps this cache honest.
    /// Each write reloads and reposts; a large multi-row apply pays one reload
    /// per row — batch FFI is the fix if that ever matters, not a cache delta.
    @discardableResult
    func upsertTag(_ upsert: UpsertRowTag) throws -> RowTag {
        let saved = try PharosCore.upsertRowTag(upsert)
        try reloadOrEvict(connectionId: upsert.connectionId)
        return saved
    }

    /// Delete tags by id and refresh. An id that no longer exists is skipped
    /// by the core, not an error.
    func removeTags(ids: [String], connectionId: String) throws {
        guard !ids.isEmpty else { return }
        _ = try PharosCore.deleteRowTags(ids: ids)
        try reloadOrEvict(connectionId: connectionId)
    }

    /// Reload after a committed write. On failure, evict the connection's
    /// cache entry so `loadIfNeeded` reads SQLite fresh next time — a stale
    /// index would silently show pre-write tags with no self-repair path.
    private func reloadOrEvict(connectionId: String) throws {
        do { try reload(connectionId: connectionId) }
        catch {
            tagsByIdentity.removeValue(forKey: connectionId)
            post(connectionId: connectionId)
            throw error
        }
    }

    /// Create a label with the next palette colour. Posts a GLOBAL change
    /// (no connection id), because the palette serves every connection.
    @discardableResult
    func createLabel(name: String) throws -> TagLabel {
        let label = try PharosCore.createTagLabel(
            CreateTagLabel(name: name,
                           colorIndex: labels.count % TagLabelPalette.colors.count))
        labels = try PharosCore.loadTagLabels()
        post(connectionId: nil)
        return label
    }

    // MARK: - Unified tags
    //
    // The Phase 4 model. Tags are GLOBAL: a tag matches in every connection,
    // every database and every schema, because an entity is the same entity
    // everywhere — that cross-dataset overlap is the analytic payoff the model
    // exists for. There is deliberately no connection key anywhere below, and a
    // connection switch does not touch this cache.
    //
    // These members sit beside the per-connection row-tag ones until the grid
    // moves across; the old half then goes.

    private(set) var tags: [Tag] = []

    /// The probe index, rebuilt on every store change rather than per result.
    /// Building it here is what keeps the per-cell matching cost independent of
    /// how many tags and tuples exist.
    private(set) var tagIndex = TagTupleMatcher.Index()

    private var tagsLoaded = false

    /// Read the tags once. Safe to call from anywhere; later calls cost nothing.
    func loadTagsIfNeeded() throws {
        guard !tagsLoaded else { return }
        try reloadTags()
    }

    /// Re-read every tag and rebuild the index, then post a GLOBAL change.
    ///
    /// The two assignments happen after the FFI call returns, so a failure
    /// part-way leaves the previous state untouched rather than half-updated.
    func reloadTags() throws {
        let loaded = try PharosCore.loadTags()
        tags = loaded
        tagIndex = TagTupleMatcher.buildIndex(loaded)
        tagsLoaded = true
        post(connectionId: nil)
    }

    func tag(id: String) -> Tag? { tags.first { $0.id == id } }

    /// Create a tag with its first tuples. The write is followed by a reload,
    /// not a hand-applied delta: the core mints ids and absorbs duplicate
    /// tuples, so only a re-read is honest about what was stored.
    @discardableResult
    func createTag(_ create: CreateTag) throws -> Tag {
        let saved = try PharosCore.createTag(create)
        try reloadTagsOrEvict()
        return saved
    }

    /// Grow an existing tag. Returns how many tuples were actually inserted.
    @discardableResult
    func addTuples(_ payload: AddTagTuples) throws -> Int {
        let inserted = try PharosCore.addTagTuples(payload)
        try reloadTagsOrEvict()
        return inserted
    }

    /// Remove individual tuples — the "Remove From Tag" path. A tag that loses
    /// every tuple survives: it is still a named case, and Phase 5's manage
    /// sheet is where a tag is deleted outright.
    func removeTuples(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try PharosCore.deleteTagTuples(ids: ids)
        try reloadTagsOrEvict()
    }

    func deleteTag(id: String) throws {
        _ = try PharosCore.deleteTag(id: id)
        try reloadTagsOrEvict()
    }

    @discardableResult
    func updateTag(_ update: UpdateTag) throws -> Tag? {
        let updated = try PharosCore.updateTag(update)
        try reloadTagsOrEvict()
        return updated
    }

    /// Reload after a committed write. On failure, drop the cache so the next
    /// `loadTagsIfNeeded` reads SQLite fresh — a stale index would silently show
    /// pre-write tags with no self-repair path.
    private func reloadTagsOrEvict() throws {
        do { try reloadTags() }
        catch {
            tags = []
            tagIndex = TagTupleMatcher.Index()
            tagsLoaded = false
            post(connectionId: nil)
            throw error
        }
    }
}
