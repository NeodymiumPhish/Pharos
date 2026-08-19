import Foundation

// MARK: - InspectorOwner

/// Which surface last WROTE the shared Inspector pane.
///
/// The right-hand pane has three unrelated writers: the results area (the
/// grid's row detail and the chart's selection summary), the schema browser's
/// node detail, and the workspace-history SQL preview. Nothing in the pane
/// itself said which of them put the current content there, so any writer that
/// blanked the pane destroyed whatever another had left in it — running a
/// query cleared the grid's selection as a side effect, and that wiped the
/// table detail the analyst was reading.
enum InspectorOwner: Equatable {
    /// Nobody: the pane is showing its "No Selection" placeholder.
    case none
    /// The results area — `ResultsGridVC`'s row detail and the chart's
    /// selection summary. ONE owner covers both: they are two views of the
    /// same result set, so either replacing the other is legitimate.
    case results
    /// The schema browser's table / partition / column detail.
    case schemaBrowser
    /// The workspace-history SQL preview.
    case sqlView
}

// MARK: - InspectorOwnership

/// The rule that decides whether a writer may blank the shared Inspector.
enum InspectorOwnership {

    /// May `writer` blank the pane, when `currentOwner` put what is on screen there?
    ///
    /// Only while it still owns that content. A writer's selection can empty
    /// itself for reasons the USER never asked for — a new result set rebuilds
    /// the grid and clears its selection — and such a writer has no standing to
    /// speak for a pane that now belongs to somebody else.
    ///
    /// `.none` can never withdraw: it names no writer, and the pane it would
    /// blank is already blank.
    static func allowsWithdrawal(currentOwner: InspectorOwner, writer: InspectorOwner) -> Bool {
        writer != .none && currentOwner == writer
    }
}
