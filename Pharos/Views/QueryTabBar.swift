import AppKit
import Combine

/// Custom tab bar view showing open query tabs.
class QueryTabBar: NSView {

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onDoubleClickTab: ((String) -> Void)?

    private var tabs: [QueryTab] = []
    private var activeTabId: String?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let newTabButton = NSButton()

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        // Stack view for tab items
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view for horizontal scrolling when many tabs
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView

        // New tab button
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.bezelStyle = .recessed
        newTabButton.isBordered = false
        newTabButton.imageScaling = .scaleProportionallyDown
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.toolTip = "New Query (Cmd+T)"

        addSubview(scrollView)
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -2),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 24),
            newTabButton.heightAnchor.constraint(equalToConstant: 24),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        // Observe state
        stateManager.$tabs
            .combineLatest(stateManager.$activeTabId)
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs, activeId in
                self?.tabs = tabs
                self?.activeTabId = activeId
                self?.rebuildTabs()
            }
            .store(in: &cancellables)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    // MARK: - Rebuild

    private func rebuildTabs() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for tab in tabs {
            let tabView = TabItemView(tab: tab, isActive: tab.id == activeTabId)
            tabView.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            tabView.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            tabView.onDoubleClick = { [weak self] in self?.onDoubleClickTab?(tab.id) }
            stackView.addArrangedSubview(tabView)
        }

        // Scroll to active tab
        if let activeId = activeTabId,
           let activeView = stackView.arrangedSubviews.first(where: {
               ($0 as? TabItemView)?.tabId == activeId
           }) {
            DispatchQueue.main.async {
                activeView.scrollToVisible(activeView.bounds)
            }
        }
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Bottom border
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        path.stroke()
    }
}

// MARK: - Tab Item View

private class TabItemView: NSView {

    let tabId: String
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dirtyDot = NSView()
    private let isActive: Bool

    init(tab: QueryTab, isActive: Bool) {
        self.tabId = tab.id
        self.isActive = isActive
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tab.name

        // Label
        label.stringValue = tab.name
        label.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !isActive && !tab.isDirty

        // Dirty indicator
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.isHidden = !tab.isDirty

        // Executing spinner
        if tab.isExecuting {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 14),
                spinner.heightAnchor.constraint(equalToConstant: 14),
            ])
            closeButton.isHidden = true
        }

        addSubview(dirtyDot)
        addSubview(label)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            dirtyDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),

            label.leadingAnchor.constraint(equalTo: dirtyDot.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -2),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(tabClicked))
        addGestureRecognizer(click)

        // Double click gesture
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(tabDoubleClicked))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        click.delaysPrimaryMouseButtonEvents = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            bounds.fill()

            // Bottom highlight bar
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }

        // Right separator
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - 0.5, y: 4))
        path.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY - 4))
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        if let tab = AppStateManager.shared.tabs.first(where: { $0.id == tabId }) {
            closeButton.isHidden = !isActive && !tab.isDirty
        }
    }

    @objc private func tabClicked() { onSelect?() }
    @objc private func tabDoubleClicked() { onDoubleClick?() }
    @objc private func closeTapped() { onClose?() }
}
