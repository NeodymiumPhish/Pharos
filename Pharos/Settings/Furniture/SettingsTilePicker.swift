import AppKit

/// A radio group drawn as pictures: the Appearance chooser, where the choice
/// is best shown rather than named.
///
/// An `NSControl`, because that is what `SettingsFormBuilder.wire(_:)` takes
/// and what lets the form treat it like any other bound control —
/// `selectedIndex` plays the part `selectedSegment` plays for a segmented
/// control.
///
/// Drawn rather than layered, for the reason the rest of this kit is: a
/// dynamic `NSColor` baked into a `CGColor` resolves once and never follows an
/// appearance change. Only the chrome here is dynamic; the tile art itself is
/// fixed on purpose (see `SettingsThemeThumbnail`).
final class SettingsTilePicker: NSControl {

    struct Tile {
        let title: String
        let image: NSImage
    }

    private(set) var tiles: [Tile]
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    /// Which tile is chosen. Setting it redraws but does NOT fire the action —
    /// the form builder's refresh writes through this, and a refresh that
    /// fired the action would write the value straight back on every reload.
    var selectedIndex: Int {
        didSet { if selectedIndex != oldValue { needsDisplay = true } }
    }

    // MARK: Metrics

    /// The picture. Three of these plus captions is about 250 pt, which fits
    /// the trailing slot at the detail pane's 520 pt minimum.
    static let tileSize = NSSize(width: 68, height: 44)
    static let tileGap: CGFloat = 12
    static let captionGap: CGFloat = 5
    static let captionHeight: CGFloat = 14
    /// The selection ring sits outside the picture, so the pictures keep the
    /// same size whether or not they are chosen.
    static let ringInset: CGFloat = 3

    init(tiles: [Tile], selectedIndex: Int = 0) {
        self.tiles = tiles
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.radioGroup)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsTilePicker is built in code") }

    // MARK: Layout

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(tiles.count)
        guard n > 0 else { return .zero }
        let ring = Self.ringInset * 2
        return NSSize(
            width: n * (Self.tileSize.width + ring) + (n - 1) * Self.tileGap,
            height: Self.tileSize.height + ring + Self.captionGap + Self.captionHeight)
    }

    override var isFlipped: Bool { true }

    /// The picture's rect for tile `index`, ring excluded.
    func tileRect(_ index: Int) -> NSRect {
        let ring = Self.ringInset
        let stride = Self.tileSize.width + ring * 2 + Self.tileGap
        return NSRect(x: CGFloat(index) * stride + ring,
                      y: ring,
                      width: Self.tileSize.width,
                      height: Self.tileSize.height)
    }

    /// The whole target for tile `index` — picture, ring and caption. This is
    /// what a click and the cursor rect use, so the caption is clickable too.
    func hitRect(_ index: Int) -> NSRect {
        let picture = tileRect(index)
        return NSRect(x: picture.minX - Self.ringInset,
                      y: 0,
                      width: picture.width + Self.ringInset * 2,
                      height: bounds.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (index, tile) in tiles.enumerated() {
            let picture = tileRect(index)
            let radius = picture.height * 0.14

            tile.image.draw(in: picture)

            if index == selectedIndex {
                // A ring, not a tint: a shape survives Differentiate Without
                // Colour with no special case, which a colour-only cue would
                // not. Increase Contrast thickens it rather than changing it.
                // `NSWorkspace` directly, not `ContrastInk` / `AccessibilityDisplay`:
                // this kit is compiled standalone by scripts/test-settings-furniture.sh
                // with nothing but `Furniture/*.swift`, so a reference outside
                // this directory would break that harness.
                let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let width: CGFloat = increased ? 3.5 : 2.5
                let ringRect = picture.insetBy(dx: -Self.ringInset + width / 2,
                                               dy: -Self.ringInset + width / 2)
                let ring = NSBezierPath(roundedRect: ringRect,
                                        xRadius: radius + Self.ringInset,
                                        yRadius: radius + Self.ringInset)
                ring.lineWidth = width
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            } else if index == hovered {
                let ringRect = picture.insetBy(dx: -Self.ringInset + 0.75,
                                               dy: -Self.ringInset + 0.75)
                let ring = NSBezierPath(roundedRect: ringRect,
                                        xRadius: radius + Self.ringInset,
                                        yRadius: radius + Self.ringInset)
                ring.lineWidth = 1.5
                NSColor.separatorColor.setStroke()
                ring.stroke()
            }

            drawCaption(tile.title, under: picture, selected: index == selectedIndex)
        }
    }

    private func drawCaption(_ text: String, under picture: NSRect, selected: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let box = NSRect(x: picture.minX - Self.tileGap / 2,
                         y: picture.maxY + Self.captionGap,
                         width: picture.width + Self.tileGap,
                         height: Self.captionHeight)
        NSAttributedString(string: text, attributes: attributes).draw(in: box)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = (0..<tiles.count).first { hitRect($0).contains(point) }
        if hit != hovered { hovered = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = (0..<tiles.count).first(where: { hitRect($0).contains(point) }) else { return }
        choose(hit)
    }

    /// Pick a tile AND tell the target — the one path a user gesture takes.
    private func choose(_ index: Int) {
        selectedIndex = index
        sendAction(action, to: target)
    }

    override func resetCursorRects() {
        for index in (0..<tiles.count) {
            addCursorRect(hitRect(index), cursor: .pointingHand)
        }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !tiles.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123, 126:  // ←, ↑
            choose(max(0, selectedIndex - 1))
        case 124, 125:  // →, ↓
            choose(min(tiles.count - 1, selectedIndex + 1))
        default:
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        let ring = tileRect(selectedIndex).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
        NSBezierPath(roundedRect: ring, xRadius: 8, yRadius: 8).fill()
    }

    override var focusRingMaskBounds: NSRect {
        tileRect(selectedIndex).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
    }

    // MARK: Accessibility

    /// The child elements, made ONCE and kept.
    ///
    /// Not rebuilt per call, which is the trap here: elements returned from
    /// `accessibilityChildren()` are not retained by the accessibility server,
    /// so a fresh array every time is released the moment the call returns and
    /// the server reports a radio group with NO children — correct role,
    /// nothing inside it. Built lazily because the frames are in SCREEN
    /// coordinates and there is no screen until the view has a window.
    private var childElements: [NSAccessibilityElement] = []

    private func rebuildAccessibilityChildren() {
        guard window != nil else { return }
        if childElements.count != tiles.count {
            childElements = (0..<tiles.count).map { _ in NSAccessibilityElement() }
        }
        for index in 0..<tiles.count {
            let element = childElements[index]
            // The factory has no counterpart that mutates in place, so the
            // role, label and parent are set directly.
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(tiles[index].title)
            element.setAccessibilityFrame(convertToScreenIfPossible(hitRect(index)))
            element.setAccessibilityValue(index == selectedIndex ? 1 : 0)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        rebuildAccessibilityChildren()
        return childElements
    }


    override func accessibilityValue() -> Any? {
        (0..<tiles.count).contains(selectedIndex) ? tiles[selectedIndex].title : nil
    }

    /// An element made for a view that is not in a window yet has no screen to
    /// convert into; a zero frame is the honest answer there.
    private func convertToScreenIfPossible(_ rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
