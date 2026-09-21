import AppKit

/// The document view of a settings pane's scroll view. Flipped, so the form
/// hangs from the top and a short pane sits at the top of the scroll area
/// rather than at the bottom.
final class SettingsFormDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Wraps a pane's content in a transparent, vertical-only scroll view whose
/// document is exactly as wide as the clip. Content therefore WRAPS at the
/// pane's width; it never scrolls sideways.
enum SettingsFormScroll {

    static func make(content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // The scroll view insets itself by the window's titlebar and toolbar,
        // which is what lets a pane scroll UNDER them. Its host must therefore
        // pin it to the window's top edge, not to the safe area, or the inset
        // lands twice.
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFormDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            // The clip's width, not the scroll view's: with legacy scrollers
            // the clip is narrower by the scroller, and the document must
            // follow it or the last column hides under the bar.
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        return scroll
    }

    /// Stacks section views (headers, boxes, footer rows) with the pane's
    /// insets and spacing, and scrolls the result.
    static func makePane(sections: [NSView]) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.sectionSpacing
        stack.edgeInsets = NSEdgeInsets(top: SettingsMetrics.paneInsetTop,
                                        left: SettingsMetrics.paneInsetH,
                                        bottom: SettingsMetrics.paneInsetBottom,
                                        right: SettingsMetrics.paneInsetH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections { stack.addArrangedSubview(section) }
        // After every section is in; it subtracts the edge insets itself.
        stack.spanArrangedSubviewsFullWidth()
        return make(content: stack)
    }
}
