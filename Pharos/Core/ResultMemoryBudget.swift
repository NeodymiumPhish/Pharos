import Foundation

/// Which held results to move out of memory when all windows together hold
/// more result rows than Settings ▸ Results allows. Pure: no AppKit, no files,
/// so `scripts/test-result-memory-budget.sh` can test every rule.
///
/// A result that is moved out is "spilled": its block is written to a file in
/// the Caches folder and the table reads that file through a memory map. The
/// card keeps its result, and showing it again needs no decode: the system
/// reads the pages back as the grid touches them, and can drop them again
/// under memory pressure, because they are clean file-backed pages.
enum ResultMemoryBudget {
    /// One result that a window holds.
    struct Held: Equatable {
        /// The card id (unique across windows).
        let id: String
        /// The block size (`ResultTable.byteCount`).
        let bytes: Int
        /// When the result was last on screen, as a monotonic count; lower is
        /// longer ago.
        let lastShown: UInt64
        /// The result its window shows now. The grid holds those rows, so a
        /// spill would free nothing, and the user is looking at it.
        let isDisplayed: Bool
        /// Already reading from its spill file.
        let isSpilled: Bool
    }

    /// The limit in bytes for `percent` of `physicalMemory`, or nil when the
    /// budget is off (0 %). Settings ▸ Results keeps the percent; 25 is the
    /// default.
    static func limitBytes(percent: Int, physicalMemory: UInt64) -> Int? {
        guard percent > 0 else { return nil }
        let clamped = UInt64(min(percent, 100))
        // Multiply first: dividing first drops the remainder (4 GB came out
        // 21 bytes short). No Mac has memory near UInt64.max / 100.
        return Int(clamp: physicalMemory * clamped / 100)
    }

    /// The results to spill, least recently shown first, until the results
    /// still in memory fit `limit`. Never one on screen or already spilled;
    /// when only those are left, the total stays over the limit.
    static func toSpill(_ held: [Held], limit: Int) -> [String] {
        var inMemory = held.filter { !$0.isSpilled }.reduce(0) { $0 + $1.bytes }
        guard inMemory > limit else { return [] }
        var out: [String] = []
        let candidates = held
            .filter { !$0.isSpilled && !$0.isDisplayed }
            .sorted { ($0.lastShown, $0.id) < ($1.lastShown, $1.id) }
        for candidate in candidates where inMemory > limit {
            out.append(candidate.id)
            inMemory -= candidate.bytes
        }
        return out
    }
}

private extension Int {
    init(clamp value: UInt64) { self = value > UInt64(Int.max) ? Int.max : Int(value) }
}
