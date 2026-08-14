import Foundation

/// Parses the 0-based column index from a "col_N" identifier string.
///
/// Lives in its own file, not on `ResultsGridVC`, because six grid files call
/// it and a standalone suite that compiles only one of them (see
/// `scripts/test-tag-copy-export.sh`) must link the REAL function — a copy
/// pasted into a harness would keep passing after the identifier scheme moved.
func colIndex(from identifier: String) -> Int? {
    guard identifier.hasPrefix("col_") else { return nil }
    return Int(identifier.dropFirst(4))
}
