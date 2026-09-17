import AppKit
import Combine

/// The editor's tab bar: a native NSSegmentedControl with capsule style.
///
/// Layout: [  ‹SegmentedControl›  ] [+ add]
class PaneTabBar: NSView {

    /// The window's session, for the context-menu commands that act on the
    /// tab set directly. Weak: the bar lives inside the window whose session
    /// this is.
    weak var session: WindowSession?

    // MARK: - Callbacks

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onDoubleClickTab: ((String) -> Void)?

    // MARK: - State

    private var tabs: [QueryTab] = []
    private var activeTabId: String?

    // MARK: - UI Elements

    private let addButton = NSButton()
    /// Internal, not private: the layout suite reads segment widths and labels
    /// off the real control rather than off a mirror of it.
    let segmentedControl = NSSegmentedControl()

    /// The close slot of each segment: a ✕, or the unsaved dot, or nothing.
    /// See `closeSlotGlyph(at:)` for which.
    private var closeButtons: [NSButton] = []

    /// Overlay that draws pulsing dots on segments whose tabs are executing.
    private let pulseOverlay = PaneTabBarPulseOverlay()

    /// Tracking area for hover detection on the segmented control.
    private var segmentTrackingArea: NSTrackingArea?
    /// The segment index currently being hovered (-1 if none).
    private var hoveredSegmentIndex: Int = -1

    // Layout constants
    private let addButtonWidth: CGFloat = 30
    private let barHeight: CGFloat = 32
    private let segmentInsetH: CGFloat = 4
    private let segmentInsetV: CGFloat = 4

    // MARK: - Size-to-fit metrics

    /// A tab is as wide as its title needs, up to this. Past it the title is
    /// truncated with an ellipsis — by this class, not by AppKit: a capsule
    /// segment CLIPS a label that does not fit (measured: the ink of a 325pt
    /// title in a 120pt segment ran from 0 to 117), it does not truncate it.
    static let maxTabWidth: CGFloat = 220
    /// The floor for the equal-width fallback when the titles will not all
    /// fit at their natural widths.
    static let minTabWidth: CGFloat = 80
    /// Where a left-aligned label's ink starts inside a capsule segment
    /// (measured offscreen, selected and not, light and dark: 12pt).
    static let titleLeadingPad: CGFloat = 12
    /// Title → close slot → trailing edge. The close slot is reserved whether
    /// or not anything is drawn in it, so a title never sits under the ✕.
    static let titleCloseGap: CGFloat = 6
    static let closeSlotWidth: CGFloat = 16
    static let closeTrailingPad: CGFloat = 6
    /// Everything in a segment that is not title.
    static var titleChrome: CGFloat {
        titleLeadingPad + titleCloseGap + closeSlotWidth + closeTrailingPad
    }
    /// Blank kept in front of an executing tab's title so the pulse dot
    /// (`PaneTabBarPulseOverlay`, drawn 8–14pt in) does not sit on its first
    /// letter. An en space is 6.5pt at 13pt: the title starts at 18.5pt, 4.5pt
    /// clear of the dot.
    static let executingTitlePrefix = "\u{2002}"

    /// The font the control lays its labels out in; the width sums use the
    /// same one so they agree with the ink.
    private var labelFont: NSFont {
        segmentedControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
    }

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true

        // Add button (+): one click adds a tab. It keeps its slot at the bar's
        // trailing edge however short the tab run is (the macOS tab-bar
        // convention), so it never drifts as tabs come and go.
        let addConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?.withSymbolConfiguration(addConfig)
        addButton.toolTip = "New Tab"
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.imageScaling = .scaleNone
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addTabTapped)
        addSubview(addButton)

        // Segmented control
        segmentedControl.segmentStyle = .capsule
        segmentedControl.trackingMode = .selectOne
        segmentedControl.controlSize = .regular
        segmentedControl.selectedSegmentBezelColor = NSColor.controlColor
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        addSubview(segmentedControl)

        pulseOverlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(pulseOverlay)
    }

    // MARK: - Public API

    func update(tabs: [QueryTab], activeTabId: String?) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        rebuildSegments()
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    /// The room the tab run may take: the bar less the `+` slot and the insets.
    private var availableTabWidth: CGFloat {
        max(0, bounds.width - addButtonWidth - segmentInsetH * 2)
    }

    private func layoutSubviews() {
        // Add button at trailing edge
        addButton.frame = NSRect(x: bounds.width - addButtonWidth, y: 0, width: addButtonWidth, height: barHeight)

        // Segments size to their titles, or fall back to equal widths; the
        // control is exactly as wide as its segments, pinned leading.
        let available = availableTabWidth
        let widths = segmentWidths(fitting: available)
        let font = labelFont
        for (i, w) in widths.enumerated() where i < tabs.count {
            segmentedControl.setWidth(w, forSegment: i)
            let title = Self.truncatedTitle(segmentLabel(for: tabs[i]), toFit: w - Self.titleChrome, font: font)
            if segmentedControl.label(forSegment: i) != title {
                segmentedControl.setLabel(title, forSegment: i)
            }
        }
        segmentedControl.frame = NSRect(
            x: segmentInsetH,
            y: segmentInsetV,
            width: min(widths.reduce(0, +), available),
            height: barHeight - segmentInsetV * 2
        )

        layoutCloseButtons()

        // Overlay covers the same frame as the segmented control.
        pulseOverlay.frame = segmentedControl.frame
        refreshPulseOverlay()
        // The hover rect follows the control's frame, which just moved.
        updateTrackingAreas()
    }

    /// The natural width of each tab: its full title plus the chrome, capped
    /// at `maxTabWidth`. Public to the layout suite.
    func naturalSegmentWidths() -> [CGFloat] {
        let font = labelFont
        return tabs.map { tab in
            let text = ceil((segmentLabel(for: tab) as NSString).size(withAttributes: [.font: font]).width)
            return min(Self.maxTabWidth, text + Self.titleChrome)
        }
    }

    /// Natural widths when they all fit in `available`; otherwise every tab
    /// gets the same share, floored at `minTabWidth` (titles then truncate).
    private func segmentWidths(fitting available: CGFloat) -> [CGFloat] {
        let natural = naturalSegmentWidths()
        guard !natural.isEmpty else { return [] }
        if natural.reduce(0, +) <= available { return natural }
        let equal = max(Self.minTabWidth, floor(available / CGFloat(natural.count)))
        return Array(repeating: equal, count: natural.count)
    }

    /// `title` if it fits in `width`, else the longest prefix that does with
    /// an ellipsis after it. Pure, so the suite can pin it directly.
    static func truncatedTitle(_ title: String, toFit width: CGFloat, font: NSFont) -> String {
        func fits(_ s: String) -> Bool {
            (s as NSString).size(withAttributes: [.font: font]).width <= width
        }
        if fits(title) { return title }
        let ellipsis = "\u{2026}"
        let chars = Array(title)
        var low = 0, high = chars.count
        // Largest prefix length whose "prefix…" fits; 0 → the ellipsis alone.
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(String(chars[0..<mid]) + ellipsis) { low = mid } else { high = mid - 1 }
        }
        return String(chars[0..<low]) + ellipsis
    }

    private func layoutCloseButtons() {
        let segFrame = segmentedControl.frame
        let count = segmentedControl.segmentCount
        guard count > 0, !closeButtons.isEmpty else { return }

        let closeSize = Self.closeSlotWidth

        var segX: CGFloat = 0
        for i in 0..<count {
            let segW = segmentedControl.width(forSegment: i)

            if i < closeButtons.count {
                // The close slot: at the trailing edge of the segment, inside
                // the trailing pad, vertically centred.
                let btnX = segFrame.origin.x + segX + segW - closeSize - Self.closeTrailingPad
                let btnY = segFrame.origin.y + (segFrame.height - closeSize) / 2
                closeButtons[i].frame = NSRect(x: btnX, y: btnY, width: closeSize, height: closeSize)
            }

            segX += segW
        }
    }

    // MARK: - Rebuild Segments

    private func rebuildSegments() {
        segmentedControl.segmentCount = tabs.count

        for (index, tab) in tabs.enumerated() {
            // The label itself is set in `layoutSubviews`, truncated to the
            // width the segment ends up with. Left-aligned so the title starts
            // at the leading edge and the close slot stays clear at the trailing
            // one, whatever the segment's width.
            segmentedControl.setAlignment(.left, forSegment: index)
            // "Running" is otherwise a pulsing dot drawn by the overlay — a
            // signal with no text at all, and one Reduce Motion stills. And
            // "unsaved" is a 6pt dot. The tooltip is the per-segment channel
            // AppKit does give us, so it names both.
            segmentedControl.setToolTip(Self.tooltip(for: tab), forSegment: index)
        }

        // `NSSegmentedControl` publishes its segments itself, but their
        // accessibility VALUES are not API — `setToolTip(_:forSegment:)` has no
        // accessibility counterpart, and a segment is not an `NSView` we could
        // annotate. So the running set is said once, on the control. The
        // alternative would be replacing the segmented control with eight drawn
        // buttons carrying their own elements, which is a bigger change than
        // this pass is for.
        let running = tabs.filter(\.isExecuting).map(\.name)
        segmentedControl.setAccessibilityValue(running.isEmpty
            ? nil : "Running: " + running.joined(separator: ", "))

        // Select the active segment
        if let activeId = activeTabId,
           let activeIndex = tabs.firstIndex(where: { $0.id == activeId }) {
            segmentedControl.selectedSegment = activeIndex
        } else {
            segmentedControl.selectedSegment = -1
        }

        rebuildCloseButtons()
        layoutSubviews()
        updateCloseButtonVisibility()
        needsDisplay = true
    }

    /// "<name>", "<name> — running", "<name> — unsaved", or both notes.
    static func tooltip(for tab: QueryTab) -> String {
        var notes: [String] = []
        if tab.isExecuting { notes.append("running") }
        if tab.isDirty { notes.append("unsaved") }
        return notes.isEmpty ? tab.name : "\(tab.name) — \(notes.joined(separator: ", "))"
    }

    private func refreshPulseOverlay() {
        // Compute executing indexes.
        var executing: Set<Int> = []
        for (i, tab) in tabs.enumerated() where tab.isExecuting {
            executing.insert(i)
        }

        // Compute per-segment frames in overlay-local coordinates (overlay shares
        // segmentedControl's frame, so origin is zero-relative to the overlay).
        var frames: [NSRect] = []
        var x: CGFloat = 0
        let height = segmentedControl.bounds.height
        for i in 0..<segmentedControl.segmentCount {
            let w = segmentedControl.width(forSegment: i)
            frames.append(NSRect(x: x, y: 0, width: w, height: height))
            x += w
        }

        pulseOverlay.update(executingIndexes: executing, segmentFrames: frames)
    }

    private static let closeImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        return NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(config)
    }()

    /// The unsaved marker, in the close slot. It IS the close button — the
    /// click that lands on it closes the tab, as it does in every macOS tab
    /// bar that marks unsaved documents this way — so its description says so.
    private static let unsavedDotImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(config)
    }()

    private func rebuildCloseButtons() {
        // Remove old close buttons
        for btn in closeButtons { btn.removeFromSuperview() }
        closeButtons.removeAll()
        rebuildCloseProxies()

        for i in 0..<tabs.count {
            let btn = NSButton(frame: .zero)
            btn.image = Self.closeImage
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.imageScaling = .scaleNone
            btn.contentTintColor = .tertiaryLabelColor
            btn.target = self
            btn.action = #selector(closeTabButtonTapped(_:))
            btn.tag = i
            btn.isHidden = true  // `updateCloseButtonVisibility` decides
            addSubview(btn)
            closeButtons.append(btn)
        }
    }

    // MARK: - Accessibility for the hidden close buttons

    /// One press target per tab's close button, alive whether or not the button
    /// is on screen.
    ///
    /// The buttons themselves are `isHidden` until the segment is hovered or
    /// active, and a hidden view is not in the accessibility tree — so seven of
    /// eight tabs had no reachable close at all. Keeping them visible at
    /// `alphaValue = 0` instead is not an option: AppKit hit-tests on geometry,
    /// not on opacity, so a transparent button would go on swallowing the
    /// clicks meant for its segment. These elements give the close back to the
    /// keyboard and the screen reader without putting an invisible target in
    /// the mouse's way.
    private var closeProxies: [AccessibilityProxyElement] = []

    private func rebuildCloseProxies() {
        closeProxies = tabs.enumerated().map { index, tab in
            let element = AccessibilityProxyElement.button(
                label: "Close \(tab.name)", frame: .zero, parent: self
            ) { [weak self] in
                guard let self, index < self.tabs.count else { return false }
                self.onCloseTab?(self.tabs[index].id)
                return true
            }
            // The unsaved dot is drawn in this element's slot; this is the
            // same fact, said to the screen reader.
            element.setAccessibilityValue(tab.isDirty ? "edited" : nil)
            return element
        }
    }

    override func accessibilityChildren() -> [Any]? {
        // The proxies sit ON the segments, so their frames follow the buttons
        // that would be drawn there. Refreshed on every read rather than on
        // layout: a segment's width changes whenever a tab is added, removed
        // or renamed, and AX asks for children far less often than layout runs.
        for (index, proxy) in closeProxies.enumerated() where index < closeButtons.count {
            proxy.setAccessibilityFrame(
                AccessibilityProxyElement.frameInScreen(of: closeButtons[index].frame, in: self))
        }
        var children = super.accessibilityChildren() ?? []
        children.append(contentsOf: closeProxies)
        return children
    }

    @objc private func closeTabButtonTapped(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < tabs.count else { return }
        onCloseTab?(tabs[index].id)
    }

    /// The segment's full (untruncated) title: the tab's name, with the blank
    /// for the pulse dot in front while the tab executes. Nothing marks
    /// "unsaved" here any more — that is the close slot's job.
    func segmentLabel(for tab: QueryTab) -> String {
        tab.isExecuting ? Self.executingTitlePrefix + tab.name : tab.name
    }

    // MARK: - Close slot

    /// What the close slot of a segment shows.
    enum CloseSlotGlyph: Equatable {
        /// Nothing: an inactive, clean tab the pointer is not over.
        case hidden
        /// A 6pt dot: the tab has unsaved changes and the pointer is not over
        /// it. An executing tab never shows it — its leading pulse dot is the
        /// one signal it carries, and a second dot would read as noise.
        case unsavedDot
        /// The ✕: the pointer is over the tab, or the tab is active and clean.
        case close
    }

    /// The glyph for segment `index` in the bar's current state. The one rule
    /// behind `updateCloseButtonVisibility`, exposed so the suite can pin it.
    func closeSlotGlyph(at index: Int) -> CloseSlotGlyph {
        guard index >= 0, index < tabs.count else { return .hidden }
        let tab = tabs[index]
        let isHovered = index == hoveredSegmentIndex
        let isActive = tab.id == activeTabId
        if tab.isDirty && !tab.isExecuting && !isHovered { return .unsavedDot }
        if isHovered || isActive { return .close }
        return .hidden
    }

    // MARK: - Mouse Tracking for Close Buttons

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = segmentTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: segmentedControl.frame,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        segmentTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let segLocal = convert(localPoint, to: segmentedControl)

        if let index = segmentIndex(at: segLocal) {
            if hoveredSegmentIndex != index {
                hoveredSegmentIndex = index
                updateCloseButtonVisibility()
            }
        } else {
            if hoveredSegmentIndex != -1 {
                hoveredSegmentIndex = -1
                updateCloseButtonVisibility()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegmentIndex = -1
        updateCloseButtonVisibility()
    }

    private func updateCloseButtonVisibility() {
        for (i, btn) in closeButtons.enumerated() {
            switch closeSlotGlyph(at: i) {
            case .hidden:
                btn.isHidden = true
            case .unsavedDot:
                btn.image = Self.unsavedDotImage
                btn.contentTintColor = .secondaryLabelColor
                btn.isHidden = false
            case .close:
                btn.image = Self.closeImage
                // Brighter tint when hovered directly
                btn.contentTintColor = i == hoveredSegmentIndex ? .secondaryLabelColor : .tertiaryLabelColor
                btn.isHidden = false
            }
        }
    }

    // MARK: - Segment Actions

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < tabs.count else { return }
        onSelectTab?(tabs[index].id)
    }

    // MARK: - Button Actions

    @objc private func addTabTapped() {
        onNewTab?()
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        // Check if click is within the segmented control
        guard segmentedControl.frame.contains(localPoint) else {
            super.rightMouseDown(with: event)
            return
        }

        // Determine which segment was clicked
        let segLocal = convert(localPoint, to: segmentedControl)
        guard let index = segmentIndex(at: segLocal) else {
            super.rightMouseDown(with: event)
            return
        }

        let tabId = tabs[index].id
        // Select the tab first
        onSelectTab?(tabId)
        showContextMenu(tabId: tabId, event: event)
    }

    /// Determine which segment index a point falls in.
    private func segmentIndex(at point: NSPoint) -> Int? {
        var x: CGFloat = 0
        for i in 0..<segmentedControl.segmentCount {
            let segWidth = segmentedControl.width(forSegment: i)
            if point.x >= x && point.x < x + segWidth {
                return i
            }
            x += segWidth
        }
        return nil
    }

    private func showContextMenu(tabId: String, event: NSEvent) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
        closeItem.representedObject = tabId
        closeItem.target = self
        menu.addItem(closeItem)

        let closeOthersItem = NSMenuItem(title: "Close Others", action: #selector(contextCloseOthers(_:)), keyEquivalent: "")
        closeOthersItem.representedObject = tabId
        closeOthersItem.target = self
        closeOthersItem.isEnabled = tabs.count > 1
        menu.addItem(closeOthersItem)

        let closeRightItem = NSMenuItem(title: "Close to the Right", action: #selector(contextCloseRight(_:)), keyEquivalent: "")
        closeRightItem.representedObject = tabId
        closeRightItem.target = self
        closeRightItem.isEnabled = tabIndex < tabs.count - 1
        menu.addItem(closeRightItem)

        menu.addItem(.separator())

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextDuplicate(_:)), keyEquivalent: "")
        duplicateItem.representedObject = tabId
        duplicateItem.target = self
        menu.addItem(duplicateItem)

        let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.representedObject = tabId
        renameItem.target = self
        menu.addItem(renameItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onCloseTab?(tabId)
    }

    @objc private func contextCloseOthers(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        session?.closeOtherTabs(exceptId: tabId)
    }

    @objc private func contextCloseRight(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        session?.closeTabsToRight(ofId: tabId)
    }

    @objc private func contextDuplicate(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        session?.duplicateTab(id: tabId)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onDoubleClickTab?(tabId)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Bar background — slightly darker than window to contrast with white active segment
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        // Bottom border
        ContrastInk.separator.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        borderPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        borderPath.stroke()
    }
}

/// Non-interactive overlay drawn on top of the segmented control. Renders a small
/// pulsing accent-color dot on each segment whose tab is currently executing.
/// Click-through is preserved via `hitTest(_:) -> nil`.
final class PaneTabBarPulseOverlay: NSView {
    private var executingSegmentIndexes: Set<Int> = []
    private var segmentFrames: [NSRect] = []
    private var pulseSubscription: AnyCancellable?
    private var pulseValue: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Update which segments have executing tabs, plus the per-segment frames.
    func update(executingIndexes: Set<Int>, segmentFrames: [NSRect]) {
        self.executingSegmentIndexes = executingIndexes
        self.segmentFrames = segmentFrames

        if !executingIndexes.isEmpty, pulseSubscription == nil {
            let token = PulseClock.shared.observe()
            let sub = PulseClock.shared.value.sink { [weak self] v in
                self?.pulseValue = v
                self?.needsDisplay = true
            }
            pulseSubscription = AnyCancellable {
                sub.cancel()
                token.cancel()
            }
        } else if executingIndexes.isEmpty {
            // Cancel immediately so the PulseClock refcount drops right away.
            pulseSubscription = nil
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !executingSegmentIndexes.isEmpty else { return }

        let dotSize: CGFloat = 6
        let leftPad: CGFloat = 8
        let alpha: CGFloat = 0.55 + 0.45 * pulseValue
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()

        for idx in executingSegmentIndexes {
            guard idx >= 0, idx < segmentFrames.count else { continue }
            let segFrame = segmentFrames[idx]
            let dotRect = NSRect(
                x: segFrame.minX + leftPad,
                y: segFrame.midY - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}
