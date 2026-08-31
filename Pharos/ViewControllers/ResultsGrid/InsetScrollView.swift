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
/// The scroll room past the last column lives on the DOCUMENT — see
/// `ResultsTableView.trailingScrollRoom`. It was briefly implemented here with
/// `contentInsets`, and on macOS 26 a non-zero inset re-places the corner cap
/// and the header clip, opens a hit-test pass-through inside the inset, and
/// stopped the always-visible legacy scroll bars staying visible. Nothing in
/// this class may set `contentInsets`.
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
        // created for legacy scrollers only). `super.tile()` normally puts it
        // exactly there, but it places it inset-aware, and once it drifted over
        // the strip of header where the last column's divider rests it hid the
        // divider and swallowed every click on it. Pinned as insurance: the cap
        // may cover nothing left of the scroller's own column.
        if hasVert, let corner = (documentView as? NSTableView)?.cornerView,
           corner.superview === self {
            corner.frame = NSRect(x: bounds.width - vertW, y: corner.frame.minY,
                                  width: vertW, height: corner.frame.height)
        }
    }
}
