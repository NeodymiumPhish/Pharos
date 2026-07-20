import Foundation

/// Per-axis numeric-bin metadata carried when a heatmap axis is width-bucketed,
/// so `ServerChartDataBuilder` can turn returned bucket ints into range labels +
/// `.range` drill sub-keys. The bounds/count come back as result columns
/// (`_xlo/_xhi/_xn`, `_ylo/_yhi/_yn`); this flag just says "this axis is binned".
struct PushdownLayout {
    enum Kind { case categorical, heatmap, scatter }
    var kind: Kind
    var hasSeries: Bool
    /// Set when the categorical category axis is width_bucketed (the count is
    /// nominal; the actual server-chosen count rides the `_n` result column).
    var numericBins: Int?
    /// Cap requested for a sampled scatter query (nil for non-scatter). The
    /// builder flags `wasSampled` when the row count reaches it or `hasMore`.
    var sampleCap: Int? = nil
    /// Heatmap: whether the X / Y axis is numeric-binned (width_bucketed).
    var xNumericBinned: Bool = false
    var yNumericBinned: Bool = false
}
struct PushdownQuery { var sql: String; var layout: PushdownLayout }
