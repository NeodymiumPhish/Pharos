import Foundation

struct PushdownLayout {
    enum Kind { case categorical, heatmap }
    var kind: Kind
    var hasSeries: Bool
    var numericBins: Int?     // set when the category/x axis is width_bucketed
    // aliases are fixed: categorical → _cat[, _series], _val (+ _lo,_hi for numeric)
    //                    heatmap     → _x, _y, _val
}
struct PushdownQuery { var sql: String; var layout: PushdownLayout }
