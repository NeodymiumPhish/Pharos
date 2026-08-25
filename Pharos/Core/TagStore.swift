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
    private(set) var tagIndex = TagRuleMatcher.Index()

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
        tagIndex = TagRuleMatcher.buildIndex(loaded)
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
    func addTuples(_ payload: AddTagRules) throws -> Int {
        let inserted = try PharosCore.addTagRules(payload)
        try reloadTagsOrEvict()
        return inserted
    }

    /// Replace one rule's conditions in place. Returns whether a rule moved.
    ///
    /// The reload afterwards is the same rule every write here follows: the core
    /// mints ids and absorbs duplicates, so only a re-read is honest about what
    /// was stored.
    @discardableResult
    func updateRule(_ payload: UpdateTagRule) throws -> Bool {
        let changed = try PharosCore.updateTagRule(payload)
        try reloadTagsOrEvict()
        return changed
    }

    /// Remove individual tuples — the "Remove From Tag" path. A tag that loses
    /// every tuple survives: it is still a named case, and Phase 5's manage
    /// sheet is where a tag is deleted outright.
    func removeTuples(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try PharosCore.deleteTagRules(ids: ids)
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
            tagIndex = TagRuleMatcher.Index()
            tagsLoaded = false
            postChange()
            throw error
        }
    }
}

// MARK: - TagRuleRemoving

/// `TagRemovalSheet` commits through this one capability rather than through
/// the whole store, so its standalone harness can compile the sheet without
/// this `@MainActor`, FFI-bound class. The conformance lives here so that a
/// change to `removeTuples(ids:)` fails the APP BUILD — a test double declared
/// on the far side could drift from reality in silence. The protocol itself is
/// in `TagRuleRemoving.swift`, which depends on nothing: both this file's
/// suite and the sheet's suite compile it, and neither can compile the other's
/// side.
/// `@preconcurrency`: the protocol is deliberately nonisolated (the harness
/// conforms to it without `@MainActor`), and a plain conformance from this
/// `@MainActor` class warns that it "crosses into main actor-isolated code" —
/// an error in the Swift 6 language mode. The attribute is the sanctioned
/// spelling for this exact case: it keeps the compile-time signature check
/// that makes this conformance worth having, and adds a runtime main-thread
/// check in place of the static one. Every caller is a view-controller action,
/// so every call is already on the main thread.
extension TagStore: @preconcurrency TagRuleRemoving {}

// MARK: - TagManagerCommitting

/// `@preconcurrency` for the same reason as `TagRuleRemoving` above: the
/// protocol is nonisolated so a headless harness can conform to it, and a plain
/// conformance from this `@MainActor` class is an error under the Swift 6
/// language mode. The attribute keeps the compile-time signature check that
/// makes this conformance worth having.
extension TagStore: @preconcurrency TagManagerCommitting {

    /// Apply one save.
    ///
    /// Each command goes through the store's existing methods, which re-read
    /// after every write rather than applying a hand-made delta — the core mints
    /// ids and absorbs duplicate rules, so only a re-read is honest about what
    /// was stored. That means several reloads for a multi-command save, which is
    /// acceptable because a save is a deliberate act and not a keystroke.
    func apply(_ commits: [TagManagerCommit]) throws {
        for commit in commits {
            switch commit {
            case .create(let payload): try createTag(payload)
            case .update(let payload): _ = try updateTag(payload)
            case .addRules(let payload): _ = try addTuples(payload)
            case .updateRule(let payload): _ = try updateRule(payload)
            case .deleteRules(let ids): try removeTuples(ids: ids)
            case .deleteTag(let id): try deleteTag(id: id)
            }
        }
    }
}
