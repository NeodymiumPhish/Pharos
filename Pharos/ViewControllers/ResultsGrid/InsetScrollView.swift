import AppKit

// MARK: - Header Band Claims

/// A table header that wants first claim on pointer events in the header band,
/// ahead of the scroll view's own chrome.
///
/// On macOS 26 the band around a header is layered with Liquid Glass furniture —
/// an `NSScrollPocket`, `BackdropView`s, the legacy-scroller corner cap — and the
/// header clip view passes hit-tests through wherever a content inset is in
/// force. Measured result: a click on the last column's resize handle landed on
/// a backdrop or the corner, never on the header, and the column could not be
/// resized. The header cannot defend itself from below that chrome, so the
/// scroll view asks it FIRST — see `InsetScrollView.hitTest`.
protocol HeaderBandClaiming: AnyObject {
    /// Whether a pointer at `point`, in the header's own coordinates, is on
    /// something the header must receive — a resize handle, today.
    func claimsHeaderBandPoint(_ point: NSPoint) -> Bool
}

// MARK: - Scroll View with Non-Overlapping Scrollers

/// NSScrollView subclass that positions scrollers outside the content area
/// instead of overlaying them on top of the document view.
///
/// It also keeps a little scroll room past the last column — see
/// `trailingScrollRoom`, which is what makes the end of the table reachable.
class InsetScrollView: NSScrollView {

    /// Route header-band clicks on a resize handle to the header, over whatever
    /// chrome is stacked there. See `HeaderBandClaiming` for why the header
    /// cannot win this from below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview,
           bounds.contains(convert(point, from: superview)),
           let header = (documentView as? NSTableView)?.headerView,
           header.superview != nil,
           let claiming = header as? HeaderBandClaiming {
            let inHeader = header.convert(point, from: superview)
            if inHeader.y >= 0, inHeader.y < header.bounds.height,
               claiming.claimsHeaderBandPoint(inHeader) {
                return header
            }
        }
        return super.hitTest(point)
    }

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

        // The grey cap above the vertical scroller (`NSTableView.cornerView`,
        // created for legacy scrollers only). `super.tile()` puts its LEFT edge
        // at `width − scroller − contentInsets.right`, so the trailing scroll
        // room below moved it 16pt left — directly over the strip of header
        // where the last column's divider comes to rest. There it hid the
        // divider, the funnel and the sort mark, and being the front view it
        // swallowed every click on them: the column could not be resized at
        // all. Pin it over the scroller's own column, where it caps the band
        // and covers nothing that can be interacted with.
        if hasVert, let corner = (documentView as? NSTableView)?.cornerView,
           corner.superview === self {
            corner.frame = NSRect(x: bounds.width - vertW, y: corner.frame.minY,
                                  width: vertW, height: corner.frame.height)
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
