import AppKit

// MARK: - MarkerShape

/// The SECOND channel for a signal that is otherwise carried by colour alone.
///
/// A result tab's identity is its palette colour, and a tag band's identity is
/// its palette colour. Under System Settings → Accessibility → Display →
/// Differentiate Without Color, colour is not a channel at all, so those
/// surfaces draw a distinct SHAPE per colour as well — the colour stays, the
/// shape is added. The shapes live here, in one place, so the horizontal tab
/// bar's drawn dot (`ResultTabBar`) and the vertical panel's dot
/// (`ResultTabRowCell`) cannot end up drawing different markers for the same
/// result.
///
/// Eight shapes, not six: `ResultTab.palette` cycles through EIGHT colours, and
/// a marker set smaller than the palette would hand two live tabs the same
/// shape — which is the exact failure this exists to prevent.
enum MarkerShape {
    case circle, square, triangle, diamond, ring, cross, hexagon, invertedTriangle

    /// The cycle, in index order.
    static let all: [MarkerShape] = [
        .circle, .square, .triangle, .diamond,
        .ring, .cross, .hexagon, .invertedTriangle,
    ]

    /// The shape at a marker index, wrapping. Negative indexes wrap too — the
    /// index can come from a lookup that failed, not only from a counter.
    static func shape(at index: Int) -> MarkerShape {
        guard !all.isEmpty else { return .circle }
        return all[((index % all.count) + all.count) % all.count]
    }

    /// A spoken name for the shape, for an accessibility value that wants to
    /// say what is drawn.
    var name: String {
        switch self {
        case .circle: return "circle"
        case .square: return "square"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .ring: return "ring"
        case .cross: return "cross"
        case .hexagon: return "hexagon"
        case .invertedTriangle: return "inverted triangle"
        }
    }

    // MARK: - Paths

    /// The filled outline of this shape inside `rect`.
    ///
    /// `ring` relies on the EVEN-ODD winding rule for its hole, which
    /// `fill(index:in:color:)` sets. A caller that fills the path itself must
    /// set `windingRule = .evenOdd` or the ring comes out a disc.
    func path(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        switch self {
        case .circle:
            path.appendOval(in: rect)
        case .square:
            path.appendRect(rect)
        case .triangle:
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.close()
        case .invertedTriangle:
            path.move(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.close()
        case .diamond:
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
        case .ring:
            path.appendOval(in: rect)
            path.appendOval(in: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28))
        case .cross:
            let armX = rect.width * 0.32
            let armY = rect.height * 0.32
            path.appendRect(NSRect(x: rect.midX - armX / 2, y: rect.minY,
                                   width: armX, height: rect.height))
            path.appendRect(NSRect(x: rect.minX, y: rect.midY - armY / 2,
                                   width: rect.width, height: armY))
        case .hexagon:
            let inset = rect.width * 0.25
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + inset, y: rect.minY))
            path.close()
        }
        path.windingRule = .evenOdd
        return path
    }

    /// The path for a marker index, wrapping like `shape(at:)`.
    static func markerPath(index: Int, in rect: NSRect) -> NSBezierPath {
        shape(at: index).path(in: rect)
    }

    /// Fill the marker for `index` in `color`. The one draw call both dot
    /// surfaces use, so the winding rule the ring needs cannot be forgotten at
    /// one of them.
    static func fill(index: Int, in rect: NSRect, color: NSColor) {
        color.setFill()
        markerPath(index: index, in: rect).fill()
    }

    // MARK: - Colour → marker index

    /// Where a palette colour sits in the marker cycle.
    ///
    /// Keyed by the colour's CATALOG NAME, which is appearance-independent: a
    /// system colour resolves to different RGB in light and dark mode, and a
    /// marker that changed shape when the user switched appearance would be a
    /// worse signal than no marker at all.
    ///
    /// The table names both palettes this app draws dots from — `ResultTab`'s
    /// eight and `TagPalette`'s six — because neither can be imported here: the
    /// two cells that call this compile in standalone `swiftc` harnesses that
    /// do not link the model layer. What matters is only that entries WITHIN
    /// one palette differ; a tab and a tag may share a shape, since they never
    /// appear beside each other. `MarkerShapeTests` pins both palettes' spreads
    /// so an added colour cannot silently collide.
    private static let slots: [String: Int] = [
        // ResultTab.palette, in cycle order.
        "systemBlueColor": 0,
        "systemPurpleColor": 1,
        "systemTealColor": 2,
        "systemIndigoColor": 3,
        "systemMintColor": 4,
        "systemCyanColor": 5,
        "systemBrownColor": 6,
        "systemPinkColor": 7,
        // TagPalette.colors — blue and purple are already above.
        "systemRedColor": 2,
        "systemOrangeColor": 3,
        "systemYellowColor": 4,
        "systemGreenColor": 5,
    ]

    /// The marker index for a palette colour.
    ///
    /// A colour outside the table falls back to a stable hash of its key, so an
    /// unknown colour still gets a fixed shape rather than shape 0 along with
    /// every other unknown.
    static func index(for color: NSColor) -> Int {
        let key = identityKey(color)
        if let slot = slots[key] { return slot }
        // FNV-1a. Any stable hash would do; Swift's own `hashValue` is seeded
        // per process and would change the shape between launches.
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(all.count))
    }

    /// A colour's appearance-independent identity.
    ///
    /// The catalog-name accessors RAISE for a colour that is not a catalog
    /// colour, and an Objective-C exception cannot be caught in Swift, so the
    /// type is checked first rather than tried. `withAlphaComponent` produces a
    /// non-catalog colour, which is why callers pass the BASE palette colour
    /// here and apply their alpha afterwards.
    private static func identityKey(_ color: NSColor) -> String {
        if color.type == .catalog { return color.colorNameComponent }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return "\(Int(rgb.redComponent * 255))-\(Int(rgb.greenComponent * 255))-\(Int(rgb.blueComponent * 255))"
    }

    // MARK: - Hatching

    /// Parallel lines across `rect`, at an angle and spacing that depend on
    /// `index`. Stroked over a tag band so bands differ by TEXTURE as well as
    /// by colour.
    ///
    /// A tag band is only `TaggedRowView.barWidth` across, so the angles are
    /// chosen for what survives four points: level rungs, then the two
    /// diagonals. Index 0 is deliberately the loosest so the strongest match
    /// stays the calmest band.
    static func hatchPath(forBand index: Int, in rect: NSRect) -> NSBezierPath {
        let slot = ((index % 3) + 3) % 3
        let path = NSBezierPath()
        path.lineWidth = 1
        let spacing: CGFloat = [5, 3.5, 3.5][slot]
        switch slot {
        case 0:  // level rungs
            var y = rect.minY + spacing / 2
            while y < rect.maxY {
                path.move(to: NSPoint(x: rect.minX, y: y))
                path.line(to: NSPoint(x: rect.maxX, y: y))
                y += spacing
            }
        default:  // diagonals, one leaning each way
            let leansRight = slot == 1
            var offset = rect.minY - rect.width
            while offset < rect.maxY {
                let startY = offset
                let endY = offset + rect.width
                path.move(to: NSPoint(x: rect.minX, y: leansRight ? startY : endY))
                path.line(to: NSPoint(x: rect.maxX, y: leansRight ? endY : startY))
                offset += spacing
            }
        }
        return path
    }

    /// The ink a hatch is stroked in: a luminance contrast, not a hue, because
    /// hue is the channel that has just been taken away. `labelColor` follows
    /// the appearance, so the hatch stays visible on a dark band too.
    static var hatchInk: NSColor { NSColor.labelColor.withAlphaComponent(0.65) }
}

// MARK: - ContrastInk

/// The alphas and separator colours that Increase Contrast raises.
///
/// One home for them so a surface cannot be left behind: every value is read at
/// DRAW time, and every view that draws one also redraws on
/// `AccessibilityDisplay.didChange`.
@MainActor
enum ContrastInk {

    private static var increased: Bool { AccessibilityDisplay.shared.increaseContrast }

    /// A result tab button's background, hovered and active.
    static var tabHoverAlpha: CGFloat { increased ? 0.12 : 0.05 }
    static var tabActiveAlpha: CGFloat { increased ? 0.30 : 0.15 }

    /// A tagged row's wash: the strongest band's colour behind the whole row.
    static func tagWashAlpha(isPartial: Bool) -> CGFloat {
        if increased { return isPartial ? 0.16 : 0.30 }
        return isPartial ? 0.08 : 0.15
    }

    /// The gutter's segment band — a statement's colour washed BEHIND its line
    /// numbers. Same ladder as `tagWashAlpha`, and for the same reason: the
    /// numbers have to stay readable through it.
    ///
    /// `running` is deliberately near `hovered` rather than near the 0.55–1.0
    /// swing the thin bar used to pulse through. That range is right for a 4pt
    /// stripe and wrong for a band: at band size it washes out the numbers it
    /// sits behind. The pulse's amplitude rides on top of this base.
    enum SegmentBand {
        /// Every statement, at rest — what tells the user where one ends.
        case idle
        /// The statement holding the caret, or one with a result tab's colour.
        case active
        /// The statement under the pointer.
        case hovered
        /// The statement being executed. The pulse adds `segmentBandPulseSwing`.
        case running
    }

    /// Measured, not guessed (scratch probe, 2026-09-16). Over the editor
    /// background, a band at 0.15 moves the surface by a contrast ratio of only
    /// ~1.20, and 0.32 by ~1.50 — the user called both too subtle. These sit
    /// near 0.5, which moves it ~2.0.
    ///
    /// The line numbers on top barely care, which is why the ladder can go this
    /// far: a tertiary-label number keeps ~1.8 (light) and ~1.9 (dark) contrast
    /// over the band at alpha 0.5, against ~1.85 on the plain background.
    /// Legibility was never the binding constraint here — visibility was.
    static func segmentBandAlpha(_ state: SegmentBand) -> CGFloat {
        switch state {
        case .idle: return increased ? 0.34 : 0.20
        case .active: return increased ? 0.68 : 0.48
        case .hovered: return increased ? 0.80 : 0.60
        case .running: return increased ? 0.72 : 0.52
        }
    }

    /// How far the running pulse moves the band's alpha. The thin bar swung
    /// 0.45; a band this size cannot.
    static var segmentBandPulseSwing: CGFloat { 0.08 }

    /// Hairlines: a bar's edge, a toolbar's rule, the grid's own lines.
    /// `separatorColor` is designed to be barely there, which is the wrong
    /// answer when the user has asked for contrast.
    static var separator: NSColor { increased ? .tertiaryLabelColor : .separatorColor }

    /// The ground behind the content pane's chrome rows — the editor tab bar,
    /// the header row under it and the results action bar.
    ///
    /// Light mode is the reason this exists. On macOS 26 `controlBackgroundColor`,
    /// `windowBackgroundColor` and `controlColor` all resolve to pure WHITE in
    /// Light, so a white lit capsule on a white bar read at a contrast of 1.06
    /// (measured) and the selected tab could not be told from the others.
    /// Finder gets its grey tab bar from the window's chrome material; this is
    /// the same idea as a colour: Light → the control ground blended 12 % toward
    /// black (≈0.88, 18 % with Increase Contrast), Dark → the control ground as
    /// it is, where the lit capsule already stands 1.4× off the track.
    ///
    /// A dynamic provider, so it re-resolves for every appearance it is drawn
    /// in; the views that paint it also redraw on `AccessibilityDisplay.didChange`.
    static var chromeGround: NSColor {
        let fraction: CGFloat = increased ? 0.18 : 0.12
        return NSColor(name: nil) { appearance in
            var resolved = NSColor.controlBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                let base = NSColor.controlBackgroundColor
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    resolved = base.usingColorSpace(.deviceRGB) ?? base
                } else {
                    resolved = base.blended(withFraction: fraction, of: .black) ?? base
                }
            }
            return resolved
        }
    }

    /// The results table's grid lines. Named apart from `separator` because the
    /// two are set in different places and could reasonably diverge later.
    static var gridLine: NSColor { separator }
}

// MARK: - MarkerDotView

/// The colour dot in a vertical result-tab row.
///
/// Was a plain `NSView` with a corner radius; it needs a `draw(_:)` of its own
/// only so that Differentiate Without Color can put a SHAPE in the same eight
/// points. With the setting off it behaves exactly as before — a layer-backed
/// disc — so nothing about the ordinary look changed.
final class MarkerDotView: NSView {

    /// The palette colour, at full strength. The marker index is read from
    /// THIS, never from the faded stale variant: `withAlphaComponent` strips a
    /// system colour's catalog identity, and the shape would then be a hash of
    /// its resolved RGB and would change with the appearance.
    private(set) var baseColor: NSColor = .clear
    private(set) var isStale = false

    private var displayObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayObserver = NotificationCenter.default.addObserver(
            forName: AccessibilityDisplay.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    /// The drawn colour: the palette colour, faded when the result is stale.
    var effectiveColor: NSColor {
        isStale ? baseColor.withAlphaComponent(0.4) : baseColor
    }

    func configure(color: NSColor, isStale: Bool) {
        self.baseColor = color
        self.isStale = isStale
        apply()
    }

    /// The marker this dot draws, or nil when it is drawing a plain disc.
    var markerIndex: Int? {
        AccessibilityDisplay.shared.differentiateWithoutColor
            ? MarkerShape.index(for: baseColor) : nil
    }

    private func apply() {
        if markerIndex == nil {
            layer?.cornerRadius = bounds.width / 2
            layer?.backgroundColor = effectiveColor.cgColor
        } else {
            // The shape is drawn, so the layer must not also paint a disc
            // behind it.
            layer?.cornerRadius = 0
            layer?.backgroundColor = nil
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if markerIndex == nil { layer?.cornerRadius = bounds.width / 2 }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let markerIndex else { return }
        MarkerShape.fill(index: markerIndex, in: bounds, color: effectiveColor)
    }
}
