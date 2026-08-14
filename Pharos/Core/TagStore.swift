import Foundation

// MARK: - TagStore

/// The app's one in-memory cache of every tag, and the probe index built from
/// them.
///
/// Tags are GLOBAL: a tag matches in every connection, every database and every
/// schema, because an entity is the same entity everywhere — that cross-dataset
/// overlap is the analytic payoff the model exists for. There is deliberately
/// no connection key anywhere here, so a connect, a disconnect or a deleted
/// connection neither loads nor drops anything.
///
/// One cache, one index, and a `didChange` that always means "every grid must
/// rebuild": there is no per-connection post to filter on, so an observer needs
/// no `userInfo` at all.
///
/// `@MainActor` because every reader is a view controller and every write follows
/// a user action. The FFI calls it makes are synchronous and local (SQLite), so
/// they do not need to leave the main thread — see `PharosCore+Tags.swift`.
@MainActor
final class TagStore {

    static let shared = TagStore()

    /// Posted after any change to the cached tags. Always global, and always a
    /// main-thread post: `TagStore` is `@MainActor` and posts synchronously, so
    /// an observer can run on the caller's own stack.
    static let didChange = Notification.Name("PharosTagStoreDidChange")

    private init() {}

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

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
        postChange()
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
            postChange()
            throw error
        }
    }
}
