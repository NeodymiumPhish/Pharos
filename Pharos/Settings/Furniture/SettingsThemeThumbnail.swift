import AppKit

/// The miniature window drawn on an appearance tile — the picture Apple uses
/// in System Settings ▸ Appearance instead of the word "Light".
///
/// Drawn into an `NSImage`, not assembled from subviews: a tile is a picture,
/// it never needs to be hit-tested in pieces, and one image is what
/// `SettingsTilePicker` can scale and ring.
///
/// Every colour here is a LITERAL, and deliberately so. This art has to show
/// light and dark side by side in the SAME window, so a dynamic system colour
/// — which resolves to whatever the window's appearance is — would paint both
/// tiles identically. The values are the ones the system's own window chrome
/// uses, sampled at the two appearances.
enum SettingsThemeThumbnail {

    /// Which appearance a tile is a picture OF.
    enum Style {
        case light
        case dark
        /// Follows the system: light on the left, dark on the right, split
        /// down the middle, which is how Apple draws the same idea.
        case system
    }

    /// One tile's art at `size` points.
    static func image(_ style: Style, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            switch style {
            case .light: drawWindow(in: rect, dark: false)
            case .dark: drawWindow(in: rect, dark: true)
            case .system:
                // The light half first, then the dark half clipped to the
                // right, so the two share one outline and one corner radius.
                drawWindow(in: rect, dark: false)
                NSGraphicsContext.saveGraphicsState()
                let right = NSRect(x: rect.midX, y: rect.minY,
                                   width: rect.width / 2, height: rect.height)
                NSBezierPath(rect: right).setClip()
                drawWindow(in: rect, dark: true)
                NSGraphicsContext.restoreGraphicsState()
            }
            outline(rect)
            return true
        }
    }

    // MARK: - Pieces

    private static func drawWindow(in rect: NSRect, dark: Bool) {
        let radius = rect.height * 0.14
        let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        (dark ? Ink.darkDesktop : Ink.lightDesktop).setFill()
        body.fill()

        // The window sitting on the desktop, inset on three sides and running
        // off the bottom — the same framing as the system's own art.
        let win = NSRect(x: rect.minX + rect.width * 0.14,
                         y: rect.minY,
                         width: rect.width * 0.72,
                         height: rect.height * 0.74)
        NSGraphicsContext.saveGraphicsState()
        body.setClip()

        let winRadius = radius * 0.8
        let winPath = NSBezierPath(roundedRect: win, xRadius: winRadius, yRadius: winRadius)
        (dark ? Ink.darkWindow : Ink.lightWindow).setFill()
        winPath.fill()

        // Sidebar strip, so the picture reads as THIS app's kind of window.
        let sidebar = NSRect(x: win.minX, y: win.minY,
                             width: win.width * 0.32, height: win.height)
        NSGraphicsContext.saveGraphicsState()
        winPath.setClip()
        (dark ? Ink.darkSidebar : Ink.lightSidebar).setFill()
        NSBezierPath(rect: sidebar).fill()
        NSGraphicsContext.restoreGraphicsState()

        (dark ? Ink.darkEdge : Ink.lightEdge).setStroke()
        winPath.lineWidth = 0.5
        winPath.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }

    /// A hairline round the whole tile, so a light tile still has an edge on a
    /// light plate.
    private static func outline(_ rect: NSRect) {
        let radius = rect.height * 0.14
        let inset = rect.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        path.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    /// Fixed colours, because the point is to show both appearances at once.
    private enum Ink {
        static let lightDesktop = NSColor(srgbRed: 0.62, green: 0.71, blue: 0.83, alpha: 1)
        static let lightWindow = NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
        static let lightSidebar = NSColor(srgbRed: 0.91, green: 0.92, blue: 0.94, alpha: 1)
        static let lightEdge = NSColor(srgbRed: 0.72, green: 0.74, blue: 0.77, alpha: 1)

        static let darkDesktop = NSColor(srgbRed: 0.17, green: 0.20, blue: 0.27, alpha: 1)
        static let darkWindow = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        static let darkSidebar = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
        static let darkEdge = NSColor(srgbRed: 0.32, green: 0.32, blue: 0.34, alpha: 1)
    }
}
