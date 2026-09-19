import AppKit

/// The one home for the numbers that header text, body cells and the
/// column-width measurer must agree on. The header draws its text at
/// `cellInset`, the cell pins its label at `cellInset`, and the measurer pads
/// every sampled string by `cellInset * 2` — read them from here so a change
/// in one place cannot leave the other two behind.
/// The fonts moved to `ResultsGridStyle`, which derives them from Settings ▸
/// Results. They cannot be constants any more, and a constant beside the
/// settable value is exactly the second source of truth this type exists to
/// prevent.
enum ResultsGridMetrics {
    /// Horizontal inset from the column edge to the text, header and body alike.
    static let cellInset: CGFloat = 6
}
