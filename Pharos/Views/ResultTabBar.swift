import AppKit

/// Horizontal tab bar displaying result tabs below the action bar.
/// Each tab shows a colored dot, a line-range label, and a close button on hover.
class ResultTabBar: NSView {

    // MARK: - Callbacks

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onViewDetail: ((String) -> Void)?
    var onRenameTab: ((String) -> Void)?

    // MARK: - State

    private var resultTabs: [ResultTab] = []
    private var activeTabId: String?
    private var hoveredTabId: String?

    // MARK: - UI Elements

    private let scrollView = NSScrollView()
    private let containerView = NSView()
    /// Internal, not private: the accessibility suite reads the buttons the bar
    /// built, and `accessibilityChildren` hands the same array to VoiceOver.
    private(set) var tabButtons: [ResultTabButton] = []

    private var displayObserver: NSObjectProtocol?

    // Layout constants
    private static let barHeight: CGFloat = 26
    private let tabSpacing: CGFloat = 1
    private let tabInsetH: CGFloat = 4

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true

        // The bar is a tab group and each button is a radio button inside it —
        // the AX shape AppKit gives a real `NSTabView`, which this drawn bar
        // otherwise has no way to claim.
        //
        // `setAccessibilityElement(true)` is not decoration: a plain NSView is
        // an IGNORED accessibility element, and an ignored element's children
        // are hoisted into its parent. Without it the tabs really did appear in
        // the tree — hanging off the content pane, with nothing to say they
        // were a group of tabs at all. Seen in the live AX walk.
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Results")
        setAccessibilityIdentifier("results.tabBar")

        displayObserver = NotificationCenter.default.addObserver(
            forName: AccessibilityDisplay.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplay = true
                for button in self.tabButtons { button.needsDisplay = true }
            }
        }

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = containerView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    func update(tabs: [ResultTab], activeTabId: String?) {
        self.resultTabs = tabs
        self.activeTabId = activeTabId
        rebuildTabs()
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: - Rebuild Tabs

    private func rebuildTabs() {
        // Remove old buttons
        for button in tabButtons {
            button.removeFromSuperview()
        }
        tabButtons.removeAll()

        var x: CGFloat = tabInsetH

        for tab in resultTabs {
            let isActive = tab.id == activeTabId
            let button = ResultTabButton(
                resultTab: tab,
                isActive: isActive,
                target: self,
                selectAction: #selector(tabSelected(_:)),
                closeAction: #selector(tabClosed(_:))
            )
            button.frame = NSRect(x: x, y: 2, width: button.preferredWidth, height: Self.barHeight - 4)
            containerView.addSubview(button)
            tabButtons.append(button)
            x += button.preferredWidth + tabSpacing
        }

        x += tabInsetH

        // Size the container to fit all tabs
        containerView.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.bounds.width), height: Self.barHeight)

        // Auto-scroll to reveal the active tab
        if let activeId = activeTabId,
           let button = tabButtons.first(where: { $0.resultTabId == activeId }) {
            scrollView.contentView.scrollToVisible(button.frame)
        }

        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: - Accessibility

    /// The tabs, directly under the tab group. Without this the buttons hang
    /// off the scroll view's clip view and read as the contents of a scroll
    /// area rather than as the group's tabs.
    override func accessibilityChildren() -> [Any]? {
        tabButtons
    }

    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    // MARK: - Actions

    @objc private func tabSelected(_ sender: ResultTabButton) {
        onSelectTab?(sender.resultTabId)
    }

    @objc private func tabClosed(_ sender: ResultTabButton) {
        onCloseTab?(sender.resultTabId)
    }

    // MARK: - Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = containerView.convert(localPoint, from: self)

        // Find which tab button was right-clicked
        guard let button = tabButtons.first(where: { $0.frame.contains(containerPoint) }) else {
            super.rightMouseDown(with: event)
            return
        }

        let tabId = button.resultTabId
        onSelectTab?(tabId)
        showContextMenu(tabId: tabId, event: event)
    }

    /// The item set, its order and its wiring, shared with the vertical
    /// `ResultTabsPanelVC` so the two surfaces cannot drift on what a result tab
    /// can do. The closures read this view's own callbacks at click time, so
    /// they see whatever `ContentViewController` assigned after init.
    private lazy var tabMenu: ResultTabContextMenu = {
        let builder = ResultTabContextMenu()
        builder.onViewDetail = { [weak self] id in self?.onViewDetail?(id) }
        builder.onRename = { [weak self] id in self?.onRenameTab?(id) }
        builder.onClose = { [weak self] id in self?.onCloseTab?(id) }
        return builder
    }()

    private func showContextMenu(tabId: String, event: NSEvent) {
        NSMenu.popUpContextMenu(tabMenu.menu(forTabId: tabId), with: event, for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        // Top separator
        ContrastInk.separator.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        path.stroke()
    }
}

// MARK: - ResultTabButton

/// A single tab button in the result tab bar.
///
/// Internal rather than private so `ResultTabBar.tabButtons` can be read by the
/// accessibility suite and handed to VoiceOver as the tab group's children.
class ResultTabButton: NSView {

    let resultTabId: String
    private let resultTab: ResultTab
    private let isActive: Bool
    private weak var target: AnyObject?
    private let selectAction: Selector
    private let closeAction: Selector

    private let dotSize: CGFloat = 6
    private let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private let closeButtonSize: CGFloat = 14
    private let hPadding: CGFloat = 8
    private let dotLabelGap: CGFloat = 4
    private let labelCloseGap: CGFloat = 4

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    /// Computed preferred width for this tab button.
    let preferredWidth: CGFloat

    /// The label as the eye gets it: hostile invisibles disclosed as `<U+XXXX>`.
    /// Escaped ONCE here, then used both to compute `preferredWidth` below and to
    /// draw — the button cannot be sized for different text than it shows, which
    /// two separate `escaped` calls (init and `draw`) only happened to guarantee.
    /// Tab identity is `resultTab.id`, so nothing reads this string back. It also
    /// keeps `draw` allocation-free: that runs on every hover and active swap.
    private let escapedLabel: String

    init(resultTab: ResultTab, isActive: Bool, target: AnyObject, selectAction: Selector, closeAction: Selector) {
        self.resultTab = resultTab
        self.resultTabId = resultTab.id
        self.isActive = isActive
        self.target = target
        self.selectAction = selectAction
        self.closeAction = closeAction

        // Calculate preferred width from the same escaped string `draw` renders.
        let escaped = DisplayEscape.escaped(resultTab.label)
        self.escapedLabel = escaped
        let labelSize = NSAttributedString(
            string: escaped,
            attributes: [.font: labelFont]
        ).size()
        self.preferredWidth = hPadding + dotSize + dotLabelGap + labelSize.width + labelCloseGap + closeButtonSize + hPadding

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accessibilityTabLabel)
        setAccessibilityValue(isActive ? 1 : 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Accessibility

    /// The tab as it is spoken: the label the eye reads, plus the one piece of
    /// state the tab carries that has no text of its own.
    var accessibilityTabLabel: String {
        resultTab.isStale ? "\(escapedLabel), stale" : escapedLabel
    }

    override func accessibilityPerformPress() -> Bool {
        _ = target?.perform(selectAction, with: self)
        return true
    }

    /// The close glyph, which is DRAWN rather than hosted, and which is not
    /// even painted until the tab is hovered or active. It is always in the AX
    /// tree: a hover is not a thing a keyboard or a screen reader can perform,
    /// so a close that only appears on hover would be a close that only a mouse
    /// can reach.
    private lazy var closeElement: AccessibilityProxyElement = {
        AccessibilityProxyElement.button(
            label: "Close \(escapedLabel)", frame: .zero, parent: self
        ) { [weak self] in
            guard let self else { return false }
            _ = self.target?.perform(self.closeAction, with: self)
            return true
        }
    }()

    override func accessibilityChildren() -> [Any]? {
        closeElement.setAccessibilityFrame(
            AccessibilityProxyElement.frameInScreen(of: closeRect, in: self))
        return [closeElement]
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return closeRect.contains(local) ? closeElement : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// The close glyph's hit box. One definition, read by the click, by the
    /// draw, and by the accessibility element's frame — three copies of this
    /// rect is exactly how a close target drifts out from under its glyph.
    var closeRect: NSRect {
        NSRect(
            x: bounds.width - hPadding - closeButtonSize,
            y: (bounds.height - closeButtonSize) / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if closeRect.contains(point) {
            _ = target?.perform(closeAction, with: self)
        } else {
            _ = target?.perform(selectAction, with: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background. The alphas rise under Increase Contrast — at 0.05 a
        // hovered tab is barely a tab at all.
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(ContrastInk.tabActiveAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(ContrastInk.tabHoverAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }

        var x = hPadding

        // Colour marker. A disc normally; under Differentiate Without Color a
        // shape from `MarkerShape`, keyed on the palette colour so this bar and
        // the vertical panel mark the same result the same way. The index comes
        // from the BASE colour, not the faded stale one — see `MarkerShape`.
        let dotY = (bounds.height - dotSize) / 2
        let dotRect = NSRect(x: x, y: dotY, width: dotSize, height: dotSize)
        let dotColor = resultTab.isStale ? resultTab.color.withAlphaComponent(0.4) : resultTab.color
        if AccessibilityDisplay.shared.differentiateWithoutColor {
            MarkerShape.fill(index: MarkerShape.index(for: resultTab.color),
                             in: dotRect, color: dotColor)
        } else {
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
        x += dotSize + dotLabelGap

        // Label
        let labelColor: NSColor = resultTab.isStale ? .tertiaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
        ]
        let labelStr = NSAttributedString(string: escapedLabel, attributes: attrs)
        let labelSize = labelStr.size()
        let labelY = (bounds.height - labelSize.height) / 2
        labelStr.draw(at: NSPoint(x: x, y: labelY))

        // Close button (only visible on hover or when active)
        if isHovered || isActive {
            let closeRect = self.closeRect

            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            if let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                .withSymbolConfiguration(config) {
                let tintColor: NSColor = .secondaryLabelColor
                let tinted = closeImage.image(with: tintColor)
                let imageSize = tinted.size
                let imageX = closeRect.midX - imageSize.width / 2
                let imageY = closeRect.midY - imageSize.height / 2
                tinted.draw(in: NSRect(x: imageX, y: imageY, width: imageSize.width, height: imageSize.height))
            }
        }
    }
}

// MARK: - NSImage Tinting Helper

private extension NSImage {
    func image(with tintColor: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            tintColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
