import AppKit

/// The Tag Manager's colour chooser: one round swatch per `TagPalette`
/// colour, in a row, with the chosen one ringed. A radio group, for VoiceOver
/// as well as for the eye — each swatch is a radio button named after its
/// colour, because a colour on its own says nothing to someone who cannot see
/// it.
///
/// Built the way `SettingsTilePicker` is, and sharing its selection idiom (an
/// accent-coloured ring outside the picture, a thinner separator ring on
/// hover): a ring is a SHAPE, so it survives Differentiate Without Colour
/// with no special case. The tile picker itself cannot be used here — its
/// tiles are 68 pt pictures with captions, and six of them do not fit the
/// trailing slot of a form row.
///
/// `selectedIndex` plays the part `selectedSegment` played for the segmented
/// control this replaces: -1 is "none" (no tag selected), and setting it
/// redraws but does NOT fire the action — only a user gesture does.
///
/// Drawn rather than layered, for the reason the rest of the furniture is: a
/// dynamic `NSColor` baked into a `CGColor` resolves once and never follows an
/// appearance change.
final class TagColorSwatchPicker: NSControl, NSViewToolTipOwner {

    /// The colours' names, in `TagPalette.colors` order: each swatch's
    /// VoiceOver label and tooltip. The suite pins the two lists to the same
    /// length, so a colour added to the palette cannot arrive nameless.
    static let colorNames: [String] = [
        String(localized: "Red", comment: "Tag colour name."),
        String(localized: "Orange", comment: "Tag colour name."),
        String(localized: "Yellow", comment: "Tag colour name."),
        String(localized: "Green", comment: "Tag colour name."),
        String(localized: "Blue", comment: "Tag colour name."),
        String(localized: "Purple", comment: "Tag colour name."),
    ]

    static func name(of index: Int) -> String {
        colorNames.indices.contains(index) ? colorNames[index] : ""
    }

    private let colors: [NSColor]
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    /// Which swatch is chosen; -1 for none. Setting it redraws but does NOT
    /// fire the action — the detail writes through this when it shows a tag,
    /// and a refresh that fired the action would record a recolour nobody made.
    var selectedIndex: Int = -1 {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValues()
        }
    }

    // MARK: Metrics

    /// The swatch's diameter.
    static let swatchSize: CGFloat = 18
    /// Room outside the swatch for the selection ring, so a chosen swatch is
    /// the same size as the rest.
    static let ringInset: CGFloat = 4
    static let gap: CGFloat = 6

    init(colors: [NSColor] = TagPalette.colors) {
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TagColorSwatchPicker is built in code") }

    var count: Int { colors.count }

    // MARK: Layout

    override var isFlipped: Bool { true }

    private static var cell: CGFloat { swatchSize + ringInset * 2 }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(colors.count)
        guard n > 0 else { return .zero }
        return NSSize(width: n * Self.cell + (n - 1) * Self.gap, height: Self.cell)
    }

    /// The swatch's own circle for `index`, ring excluded.
    func swatchRect(_ index: Int) -> NSRect {
        let x = CGFloat(index) * (Self.cell + Self.gap) + Self.ringInset
        return NSRect(x: x, y: Self.ringInset, width: Self.swatchSize, height: Self.swatchSize)
    }

    /// What a click on `index` hits: the swatch and its ring room.
    func hitRect(_ index: Int) -> NSRect {
        swatchRect(index).insetBy(dx: -Self.ringInset, dy: -Self.ringInset)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for (index, color) in colors.enumerated() {
            let rect = swatchRect(index)
            (isEnabled ? color : color.withAlphaComponent(0.35)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            // A hairline edge, so a yellow swatch does not dissolve into a
            // light plate.
            NSColor.separatorColor.setStroke()
            let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()

            if index == selectedIndex {
                // The tile picker's ring: accent ink, thicker under Increase
                // Contrast rather than a different idiom.
                let width: CGFloat = increased ? 3 : 2
                let ring = NSBezierPath(ovalIn: hitRect(index).insetBy(dx: width / 2, dy: width / 2))
                ring.lineWidth = width
                (isEnabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
                ring.stroke()
            } else if index == hovered, isEnabled {
                let ring = NSBezierPath(ovalIn: hitRect(index).insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NSColor.separatorColor.setStroke()
                ring.stroke()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
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
        let hit = (0..<colors.count).first { hitRect($0).contains(point) }
        if hit != hovered { hovered = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = (0..<colors.count).first(where: { hitRect($0).contains(point) }) else { return }
        choose(hit)
    }

    /// Pick a swatch AND tell the target — the one path a user gesture takes
    /// (a click, an arrow key, a VoiceOver press).
    func choose(_ index: Int) {
        guard isEnabled, (0..<colors.count).contains(index) else { return }
        selectedIndex = index
        sendAction(action, to: target)
    }

    override func resetCursorRects() {
        for index in 0..<colors.count { addCursorRect(hitRect(index), cursor: .pointingHand) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The colour's name on hover, for the same reason VoiceOver gets it.
        removeAllToolTips()
        for index in 0..<colors.count { addToolTip(hitRect(index), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                       point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = (0..<colors.count).first { hitRect($0).contains(point) }
        return index.map(Self.name(of:)) ?? ""
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !colors.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123, 126:  // ←, ↑
            choose(max(0, selectedIndex - 1))
        case 124, 125:  // →, ↓
            choose(min(colors.count - 1, max(0, selectedIndex + 1)))
        default:
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        guard (0..<colors.count).contains(selectedIndex) else {
            NSBezierPath(rect: bounds).fill()
            return
        }
        NSBezierPath(ovalIn: hitRect(selectedIndex)).fill()
    }

    override var focusRingMaskBounds: NSRect {
        (0..<colors.count).contains(selectedIndex) ? hitRect(selectedIndex) : bounds
    }

    // MARK: Accessibility

    /// The radio buttons, made ONCE and kept. The accessibility server does
    /// not retain what `accessibilityChildren()` returns, so a fresh array
    /// per call is released at once and the group reports no children
    /// (lessons, 2026-09-20). Their frames are refreshed in place.
    private lazy var childElements: [TagColorSwatchElement] = (0..<colors.count).map { index in
        let element = TagColorSwatchElement(index: index)
        element.picker = self
        element.setAccessibilityRole(.radioButton)
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(Self.name(of: index))
        return element
    }

    private func updateAccessibilityValues() {
        for element in childElements {
            element.setAccessibilityValue(element.index == selectedIndex ? 1 : 0)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        for element in childElements {
            element.setAccessibilityFrame(screenRect(hitRect(element.index)))
            element.setAccessibilityValue(element.index == selectedIndex ? 1 : 0)
            element.setAccessibilityEnabled(isEnabled)
        }
        return childElements
    }

    override func accessibilityValue() -> Any? {
        Self.colorNames.indices.contains(selectedIndex) ? Self.colorNames[selectedIndex] : nil
    }

    /// No window, no screen: a zero frame is the honest answer there.
    private func screenRect(_ rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}

/// One swatch as VoiceOver sees it: a radio button that a press chooses.
final class TagColorSwatchElement: NSAccessibilityElement {
    let index: Int
    weak var picker: TagColorSwatchPicker?

    init(index: Int) {
        self.index = index
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let picker, picker.isEnabled else { return false }
        picker.choose(index)
        return true
    }
}
