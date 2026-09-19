import AppIntents
import CoreSpotlight
import Foundation

/// Keeps the saved queries in Spotlight.
///
/// It indexes `SavedQueryEntity` values rather than bare `CSSearchableItem`s, so
/// the system knows which App Intents entity each result stands for and opens it
/// through `OpenSavedQueryIntent` — no URL scheme, and no guesswork in the
/// activity handler.
///
/// The index is the app's, not the document's: a re-identified test copy indexes
/// under its own identity and its items go when it does.
@MainActor
final class SavedQuerySpotlightIndexer {

    static let shared = SavedQuerySpotlightIndexer()

    /// The ids in the index as of the last pass, so a query the user deleted can
    /// be removed by id instead of clearing and rebuilding the whole set (which
    /// would leave a window with nothing findable).
    private var indexedIds: Set<String> = []

    /// Serialises the passes. `savedQueriesDidChange` can arrive in a burst
    /// (a batch delete posts once per row through the coalescer), and two
    /// overlapping passes would race on `indexedIds`.
    private var pending: Task<Void, Never>?

    /// Whether the change observer is registered. `start()` is no longer
    /// called exactly once at launch: Settings ▸ Security & Privacy can turn
    /// indexing off and on again while the app runs, and a second
    /// registration would reindex twice for every saved-query change.
    private var isFollowing = false

    private init() {}

    /// Index once now, and follow every later change. Calling it again
    /// reindexes but does not register a second observer.
    /// Call after `pharos_init` — it reads the saved queries out of the core.
    func start() {
        if !isFollowing {
            isFollowing = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(savedQueriesChanged),
                name: .savedQueriesDidChange,
                object: nil
            )
        }
        reindex()
    }

    /// Stop following changes, and take back everything this app put in
    /// Spotlight.
    ///
    /// The removal is NOT conditional on having started: the app can launch
    /// with the setting already off and a previous run's items still in the
    /// index, and those have to go too.
    func stop() async {
        if isFollowing {
            isFollowing = false
            NotificationCenter.default.removeObserver(
                self, name: .savedQueriesDidChange, object: nil)
        }
        await removeAll()
    }

    @objc private func savedQueriesChanged() {
        reindex()
    }

    func reindex() {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            await self?.runPass()
        }
    }

    private func runPass() async {
        let entities = SavedQueryEntity.all()
        let ids = Set(entities.map(\.id))
        let removed = indexedIds.subtracting(ids)
        indexedIds = ids

        let index = CSSearchableIndex.default()
        do {
            if !removed.isEmpty {
                try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: SavedQueryEntity.self)
            }
            if !entities.isEmpty {
                try await index.indexAppEntities(entities)
            }
            Log.state.info("Spotlight: indexed \(entities.count) saved queries, removed \(removed.count)")
        } catch {
            // Indexing is a convenience. A failure must not reach the user: the
            // saved queries are all still in the sidebar.
            Log.state.warning("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop everything this app put in Spotlight. Not called in normal running —
    /// it exists so a test copy can clean up after itself.
    func removeAll() async {
        indexedIds = []
        try? await CSSearchableIndex.default().deleteAppEntities(ofType: SavedQueryEntity.self)
    }
}
