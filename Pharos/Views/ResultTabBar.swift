import AppKit

/// Horizontal tab bar displaying result tabs below the action bar.
/// Each tab shows a colored dot, a line-range label, and a close button on hover.
class ResultTabBar: NSView {

    // MARK: - Callbacks

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?

    // MARK: - State

    private var resultTabs: [ResultTab] = []
    private var activeTabId: String?
    private var hoveredTabId: String?

    // MARK: - UI Elements

    private let scrollView = NSScrollView()
    private let containerView = NSView()
    private var tabButtons: [ResultTabButton] = []

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
    }

    // MARK: - Actions

    @objc private func tabSelected(_ sender: ResultTabButton) {
        onSelectTab?(sender.resultTabId)
    }

    @objc private func tabClosed(_ sender: ResultTabButton) {
        onCloseTab?(sender.resultTabId)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        // Top separator
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        path.stroke()
    }
}

// MARK: - ResultTabButton

/// A single tab button in the result tab bar.
private class ResultTabButton: NSView {

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

    init(resultTab: ResultTab, isActive: Bool, target: AnyObject, selectAction: Selector, closeAction: Selector) {
        self.resultTab = resultTab
        self.resultTabId = resultTab.id
        self.isActive = isActive
        self.target = target
        self.selectAction = selectAction
        self.closeAction = closeAction

        // Calculate preferred width
        let labelSize = NSAttributedString(
            string: resultTab.label,
            attributes: [.font: labelFont]
        ).size()
        self.preferredWidth = hPadding + dotSize + dotLabelGap + labelSize.width + labelCloseGap + closeButtonSize + hPadding

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if click is on the close button area
        let closeRect = NSRect(
            x: bounds.width - hPadding - closeButtonSize,
            y: (bounds.height - closeButtonSize) / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
        if closeRect.contains(point) {
            _ = target?.perform(closeAction, with: self)
        } else {
            _ = target?.perform(selectAction, with: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }

        var x = hPadding

        // Colored dot
        let dotY = (bounds.height - dotSize) / 2
        let dotColor = resultTab.isStale ? resultTab.color.withAlphaComponent(0.4) : resultTab.color
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: dotY, width: dotSize, height: dotSize)).fill()
        x += dotSize + dotLabelGap

        // Label
        let labelColor: NSColor = resultTab.isStale ? .tertiaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
        ]
        let labelStr = NSAttributedString(string: resultTab.label, attributes: attrs)
        let labelSize = labelStr.size()
        let labelY = (bounds.height - labelSize.height) / 2
        labelStr.draw(at: NSPoint(x: x, y: labelY))

        // Close button (only visible on hover or when active)
        if isHovered || isActive {
            let closeX = bounds.width - hPadding - closeButtonSize
            let closeY = (bounds.height - closeButtonSize) / 2
            let closeRect = NSRect(x: closeX, y: closeY, width: closeButtonSize, height: closeButtonSize)

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
        let image = self.copy() as! NSImage
        image.lockFocus()
        tintColor.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
