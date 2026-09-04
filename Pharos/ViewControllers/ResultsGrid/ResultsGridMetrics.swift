import AppKit

/// The one home for the numbers that header text, body cells and the
/// column-width measurer must agree on. The header draws its text at
/// `cellInset`, the cell pins its label at `cellInset`, and the measurer pads
/// every sampled string by `cellInset * 2` — read them from here so a change
/// in one place cannot leave the other two behind.
enum ResultsGridMetrics {
    /// Horizontal inset from the column edge to the text, header and body alike.
    static let cellInset: CGFloat = 6

    /// Body cell font. Monospaced so digits share one advance and a
    /// right-aligned numeric column lines up on its last digit.
    static let cellFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Body cell font for a NULL — same metrics, italic trait.
    static let cellItalicFont: NSFont = cellFont.withTraits(.italic)
}
