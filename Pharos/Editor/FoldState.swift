import Foundation

/// A single folded region, identified by UUID, referencing a range in the full (unfolded) text.
struct FoldEntry: Identifiable {
    let id: UUID
    /// Character range in the full, unmodified text storage.
    var range: NSRange
    /// Display label for the placeholder pill (e.g. " ▸ 4 lines ").
    let placeholder: String
}

/// Manages fold state as a separate data structure, completely decoupled from text storage.
/// All ranges reference the full (unfolded) text — text storage is never modified for folding.
final class FoldState {

    /// Active folds, sorted by range.location (ascending).
    private(set) var entries: [FoldEntry] = []

    // MARK: - Mutating

    /// Add a new fold. Returns the created entry.
    @discardableResult
    func add(range: NSRange, placeholder: String) -> FoldEntry {
        let entry = FoldEntry(id: UUID(), range: range, placeholder: placeholder)
        entries.append(entry)
        entries.sort { $0.range.location < $1.range.location }
        return entry
    }

    /// Remove a fold by its UUID. Returns the removed entry, or nil if not found.
    @discardableResult
    func remove(id: UUID) -> FoldEntry? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: idx)
    }

    /// Remove all folds.
    func removeAll() {
        entries.removeAll()
    }

    // MARK: - Queries

    /// Find the fold entry containing the given character index (in full-text coordinates).
    func entry(containing charIndex: Int) -> FoldEntry? {
        entries.first { NSLocationInRange(charIndex, $0.range) }
    }

    /// All folded character ranges, sorted by location. Used by FoldingLayoutManager.
    var foldedCharacterRanges: [NSRange] {
        entries.map { $0.range }
    }

    // MARK: - Text Edit Adjustment

    /// Adjust fold ranges after a text edit. Removes folds that overlap the edit, shifts
    /// folds that come after. Call this from didChangeText() or similar.
    func adjustForEdit(editedRange: NSRange, changeInLength: Int) {
        let editEnd = NSMaxRange(editedRange)

        // Remove folds that intersect the edit (reverse order to preserve indices)
        for idx in stride(from: entries.count - 1, through: 0, by: -1) {
            let foldEnd = NSMaxRange(entries[idx].range)
            if entries[idx].range.location < editEnd && foldEnd > editedRange.location {
                entries.remove(at: idx)
            }
        }

        // Shift folds that come entirely after the edit
        for idx in 0..<entries.count {
            if entries[idx].range.location >= editEnd {
                entries[idx].range.location += changeInLength
            }
        }
    }
}
