import AppKit

// MARK: - Scroll View with Non-Overlapping Scrollers

/// NSScrollView subclass that positions scrollers outside the content area
/// instead of overlaying them on top of the document view.
///
/// It also keeps a little scroll room past the last column — see
/// `trailingScrollRoom`, which is what makes the end of the table reachable.
class InsetScrollView: NSScrollView {

    /// Scroll room past the right end of the columns.
    ///
    /// Without it, scrolling stops the instant the document's right edge meets
    /// the clip's, which parks the last column's divider EXACTLY on the visible
    /// edge, against the vertical scroller and the grey corner above it. Nothing
    /// can bring it inboard from there: shrinking that column narrows the
    /// document, which lowers the scroll limit by the very same amount, so the
    /// scroll position follows the column and the divider stays pinned to the
    /// edge however far it is dragged. The end of the table is then permanently
    /// out of view and its resize handle out of reach — measured, and the reason
    /// this constant exists.
    ///
    /// 16pt: wider than the header's grab zone, so the handle is not just
    /// visible but comfortably grabbable.
    static let trailingScrollRoom: CGFloat = 16

    override func tile() {
        super.tile()

        // Only adjust the clip view's SIZE to make room for scrollers.
        // Do NOT change its origin -- super.tile() positions it correctly
        // relative to the floating header. Moving it creates a gap.
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let hasVert = hasVerticalScroller && !(verticalScroller?.isHidden ?? true)
        let hasHoriz = hasHorizontalScroller && !(horizontalScroller?.isHidden ?? true)
        let vertW = hasVert ? w : 0
        let horizH = hasHoriz ? w : 0

        var clipFrame = contentView.frame
        clipFrame.size.width = max(0, bounds.width - vertW)
        clipFrame.size.height = max(0, clipFrame.size.height - horizH)
        contentView.frame = clipFrame

        // Vertical scroller: starts below the header, spans data rows only
        let headerH = (documentView as? NSTableView)?.headerView?.frame.height ?? 0
        if hasVert, let vs = verticalScroller {
            vs.frame = NSRect(
                x: bounds.width - vertW,
                y: headerH,
                width: vertW,
                height: max(0, clipFrame.maxY - headerH)
            )
        }

        // Horizontal scroller: right below the clip view
        if hasHoriz, let hs = horizontalScroller {
            hs.frame = NSRect(x: 0, y: clipFrame.maxY, width: clipFrame.width, height: horizH)
        }

        updateTrailingScrollRoom(clipWidth: clipFrame.width)
    }

    /// Give the room only while the columns actually overflow the viewport.
    ///
    /// A right content inset also stops the document view being stretched to the
    /// full clip width, so charging for it when the columns already fit would end
    /// the rows 16pt short of the scroller for no reason at all.
    ///
    /// Writing `contentInsets` re-enters `tile()`. That settles at once: the
    /// second pass reads the same column geometry — `clipWidth` is forced above
    /// and does not depend on the inset — computes the same answer, and returns
    /// without writing.
    private func updateTrailingScrollRoom(clipWidth: CGFloat) {
        var wanted: CGFloat = 0
        if let table = documentView as? NSTableView, table.numberOfColumns > 0 {
            // The last column's own right edge: the width the table wants before
            // any stretching to fill the clip. `table.frame.width` would answer
            // the same today — it is `max(that, clipWidth - inset)`, and the test
            // below is against `clipWidth` — but it lags the columns by a layout
            // pass, and the columns are the thing actually being asked about.
            let columnsWidth = table.rect(ofColumn: table.numberOfColumns - 1).maxX
            if columnsWidth > clipWidth { wanted = Self.trailingScrollRoom }
        }

        guard contentInsets.right != wanted else { return }
        automaticallyAdjustsContentInsets = false
        contentInsets.right = wanted
    }
}
