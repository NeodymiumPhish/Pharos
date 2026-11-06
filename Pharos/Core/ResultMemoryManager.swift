import Foundation

/// Keeps the results of all windows inside Settings ▸ Results ▸ Memory for
/// results. Over the limit, the results that were shown least recently, and
/// that no window shows now, are spilled: their rows move to a memory-mapped
/// file (`ResultTable.spilled(to:)`) and the card keeps its result. The rule
/// is `ResultMemoryBudget`; this type gathers its input and does the moves.
@MainActor
final class ResultMemoryManager {
    static let shared = ResultMemoryManager()

    private init() {}

    /// Monotonic "shown" counter, and the last value per card.
    private var shownTick: UInt64 = 0
    private var lastShown: [String: UInt64] = [:]
    /// Cards whose spill is being written now.
    private var spilling: Set<String> = []
    private var checkScheduled = false

    /// Where spill files are written. Each file's name is removed as soon as
    /// it is mapped, so the folder is empty except for a moment per spill (or
    /// after a crash in that moment; `clearSpillFolder` empties it at launch).
    nonisolated static var spillFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pharos", isDirectory: true)
            .appendingPathComponent("ResultSpill", isDirectory: true)
    }

    /// Remove files a crash left behind. Called once at launch, off the main
    /// thread.
    nonisolated static func clearSpillFolder() {
        DispatchQueue.global(qos: .utility).async {
            let folder = spillFolder
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "prb" { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// A card's result is on screen now.
    func noteShown(cardId: String) {
        shownTick += 1
        lastShown[cardId] = shownTick
        scheduleCheck()
    }

    /// Results were added or grew: check the budget soon. Several calls in
    /// one burst (a run, a Load More, a restore) make one check.
    func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.checkScheduled = false
                self?.check()
            }
        }
    }

    private func check() {
        // A result just landed or grew: the blocks it replaced, and the
        // buffers pharos-core grew while it built the block, are free now,
        // but malloc keeps freed large blocks dirty for reuse (measured:
        // five runs of one 200k card left 401 MB of free large blocks).
        // Give them back.
        malloc_zone_pressure_relief(nil, 0)
        let percent = Int(AppStateManager.shared.settings.results.resultMemoryPercent)
        guard let limit = ResultMemoryBudget.limitBytes(percent: percent,
                                                        physicalMemory: ProcessInfo.processInfo.physicalMemory)
        else { return }
        var held: [ResultMemoryBudget.Held] = []
        var owner: [String: WindowSession] = [:]
        for session in AppStateManager.shared.sessions {
            let displayed = Set(session.tabs.compactMap { $0.document.displayedCardId })
            for tab in session.tabs {
                for result in session.resultStore[tab.id].results {
                    guard let rows = result.queryResult?.rows else { continue }
                    owner[result.id] = session
                    held.append(.init(id: result.id, bytes: rows.byteCount,
                                      lastShown: lastShown[result.id] ?? 0,
                                      isDisplayed: displayed.contains(result.id),
                                      isSpilled: rows.isSpilled || spilling.contains(result.id)))
                }
            }
        }
        // Forget cards no window holds any more.
        lastShown = lastShown.filter { owner[$0.key] != nil }
        for cardId in ResultMemoryBudget.toSpill(held, limit: limit) {
            guard let session = owner[cardId], let result = session.resultStore.result(forCard: cardId),
                  let query = result.queryResult else { continue }
            spill(cardId: cardId, rows: query.rows, token: query.contentToken, in: session)
        }
    }

    private func spill(cardId: String, rows: ResultTable, token: UUID, in session: WindowSession) {
        spilling.insert(cardId)
        let folder = Self.spillFolder
        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            let spilled: ResultTable?
            do {
                // A pool of its own: the write bridges the block through
                // NSData, and a global queue does not drain its pool after each
                // work item, so an autoreleased reference would keep the
                // in-memory block alive after the spill (measured).
                spilled = try autoreleasepool { try rows.spilled(to: folder) }
            } catch {
                // Disk full or no access: the result stays in memory.
                Log.ui.error("Result spill failed: \(error.localizedDescription, privacy: .public)")
                spilled = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.spilling.remove(cardId)
                    guard let spilled, let session else { return }
                    // Only onto the SAME rows: a run or a Load More that landed
                    // meanwhile made a new result, which keeps its own rows.
                    session.resultStore.mutateResult(cardId: cardId) { result in
                        guard var query = result.queryResult, query.contentToken == token else { return }
                        query.rows = spilled
                        result.queryResult = query
                    }
                    // The in-memory block is free now, but malloc keeps a freed
                    // large block for reuse and still counts it as this
                    // process's memory (measured: the footprint did not fall).
                    // Ask every zone to give free memory back.
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
    }
}
