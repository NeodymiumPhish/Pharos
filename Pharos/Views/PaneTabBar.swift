import AppKit
import Combine

/// Tab bar for a single editor pane. Features pane control buttons (close, expand),
/// pill-shaped tabs with hover states, and a "+" dropdown menu.
///
/// Layout: [X close] [↗ expand] [  ╭─Tab1─╮  ╭─Tab2─╮  ] [+ add]
class PaneTabBar: NSView {

    // MARK: - Callbacks

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onAddPane: (() -> Void)?
    var onClosePane: (() -> Void)?
    var onExpandPane: (() -> Void)?
    var onDoubleClickTab: ((String) -> Void)?
    var onReorderTabs: (([String]) -> Void)?

    // MARK: - State

    let paneId: String
    private var tabs: [QueryTab] = []
    private var activeTabId: String?
    private var isExpanded: Bool = false
    private var canClose: Bool = true
    private var isFocused: Bool = false

    // MARK: - UI Elements

    private let closePaneButton = NSButton()
    private let expandPaneButton = NSButton()
    private let addButton = NSButton()
    private var tabItemViews: [PillTabItemView] = []

    // Layout constants
    private let paneButtonWidth: CGFloat = 26
    private let addButtonWidth: CGFloat = 28
    private let barHeight: CGFloat = 28
    private let tabPadding: CGFloat = 2    // Between pills
    private let tabVerticalInset: CGFloat = 4

    // MARK: - Drag State

    private var isDragging = false
    private var dragState: DragState?

    private struct DragState {
        let draggedTabId: String
        var currentIndex: Int
        let draggedLayer: CALayer
        let tabLayers: [String: CALayer]
        let tabWidth: CGFloat
        let tabAreaX: CGFloat
        let dragOffset: CGFloat
    }

    // MARK: - Init

    init(paneId: String) {
        self.paneId = paneId
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true

        // Close pane button (X)
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closePaneButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?.withSymbolConfiguration(closeConfig)
        closePaneButton.bezelStyle = .recessed
        closePaneButton.isBordered = false
        closePaneButton.imageScaling = .scaleNone
        closePaneButton.contentTintColor = .secondaryLabelColor
        closePaneButton.target = self
        closePaneButton.action = #selector(closePaneTapped)
        addSubview(closePaneButton)

        // Expand pane button (↗)
        let expandConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        expandPaneButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand Pane")?.withSymbolConfiguration(expandConfig)
        expandPaneButton.bezelStyle = .recessed
        expandPaneButton.isBordered = false
        expandPaneButton.imageScaling = .scaleNone
        expandPaneButton.contentTintColor = .secondaryLabelColor
        expandPaneButton.target = self
        expandPaneButton.action = #selector(expandPaneTapped)
        addSubview(expandPaneButton)

        // Add button (+)
        let addConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?.withSymbolConfiguration(addConfig)
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.imageScaling = .scaleNone
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))
        addSubview(addButton)
    }

    // MARK: - Public API

    func update(tabs: [QueryTab], activeTabId: String?, isExpanded: Bool, canClose: Bool) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.isExpanded = isExpanded
        self.canClose = canClose

        // Update expand button appearance
        if isExpanded {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            expandPaneButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Collapse Pane")?.withSymbolConfiguration(config)
            expandPaneButton.contentTintColor = .controlAccentColor
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            expandPaneButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand Pane")?.withSymbolConfiguration(config)
            expandPaneButton.contentTintColor = .secondaryLabelColor
        }

        closePaneButton.isHidden = !canClose

        rebuildTabs()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        needsDisplay = true
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func layout() {
        super.layout()
        guard !isDragging else { return }
        layoutSubviews()
    }

    private func layoutSubviews() {
        var x: CGFloat = 0

        // Close pane button
        if canClose {
            closePaneButton.frame = NSRect(x: x, y: 0, width: paneButtonWidth, height: barHeight)
            x += paneButtonWidth
        }

        // Expand button
        expandPaneButton.frame = NSRect(x: x, y: 0, width: paneButtonWidth, height: barHeight)
        x += paneButtonWidth

        // Add button at trailing edge
        addButton.frame = NSRect(x: bounds.width - addButtonWidth, y: 0, width: addButtonWidth, height: barHeight)

        // Tab area fills between pane buttons and add button
        let tabAreaX = x
        let tabAreaWidth = bounds.width - x - addButtonWidth
        layoutPillTabs(x: tabAreaX, width: tabAreaWidth)
    }

    private func layoutPillTabs(x: CGFloat, width: CGFloat) {
        guard !tabItemViews.isEmpty else { return }
        let count = CGFloat(tabItemViews.count)
        let totalPadding = tabPadding * (count - 1) + tabPadding * 2 // Padding on edges too
        let tabWidth = max(40, (width - totalPadding) / count)

        for (index, tabView) in tabItemViews.enumerated() {
            let tabX = x + tabPadding + CGFloat(index) * (tabWidth + tabPadding)
            tabView.frame = NSRect(
                x: tabX,
                y: tabVerticalInset,
                width: tabWidth,
                height: barHeight - tabVerticalInset * 2
            )
        }
    }

    // MARK: - Rebuild Tabs

    private func rebuildTabs() {
        guard !isDragging else { return }

        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        for tab in tabs {
            let isActive = tab.id == activeTabId
            let tabView = PillTabItemView(tab: tab, isActive: isActive)

            tabView.onMouseDown = { [weak self] event in
                self?.handleTabMouseDown(event: event, tabId: tab.id)
            }
            tabView.onClose = { [weak self] in
                self?.onCloseTab?(tab.id)
            }
            tabView.onContextMenu = { [weak self] in
                self?.showContextMenu(tabId: tab.id)
            }

            addSubview(tabView)
            tabItemViews.append(tabView)
        }

        layoutSubviews()
        needsDisplay = true
    }

    // MARK: - Button Actions

    @objc private func closePaneTapped() {
        onClosePane?()
    }

    @objc private func expandPaneTapped() {
        onExpandPane?()
    }

    @objc private func addButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()

        let tabItem = NSMenuItem(title: "Tab", action: #selector(menuNewTab), keyEquivalent: "")
        tabItem.target = self
        tabItem.image = NSImage(systemSymbolName: "plus.square", accessibilityDescription: nil)
        menu.addItem(tabItem)

        let splitItem = NSMenuItem(title: "Editor Pane on Right", action: #selector(menuAddPane), keyEquivalent: "")
        splitItem.target = self
        splitItem.image = NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: nil)
        menu.addItem(splitItem)

        let location = NSPoint(x: 0, y: sender.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func menuNewTab() {
        onNewTab?()
    }

    @objc private func menuAddPane() {
        onAddPane?()
    }

    // MARK: - Mouse Handling for Tabs

    private func handleTabMouseDown(event: NSEvent, tabId: String) {
        guard let window = self.window else { return }

        let mouseDownPoint = event.locationInWindow
        var didDrag = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: NSEvent.foreverDuration,
                           mode: .default) { [weak self] trackedEvent, stop in
            guard let self, let trackedEvent else {
                stop.pointee = true
                return
            }

            switch trackedEvent.type {
            case .leftMouseDragged:
                if !didDrag {
                    let dx = abs(trackedEvent.locationInWindow.x - mouseDownPoint.x)
                    if dx < 5 { return }
                    didDrag = true
                    self.beginVisualDrag(tabId: tabId, mousePoint: mouseDownPoint)
                }
                self.updateVisualDrag(windowPoint: trackedEvent.locationInWindow)

            case .leftMouseUp:
                if didDrag {
                    self.endVisualDrag()
                } else {
                    if trackedEvent.clickCount == 2 {
                        self.onDoubleClickTab?(tabId)
                    } else {
                        self.onSelectTab?(tabId)
                    }
                }
                stop.pointee = true

            default:
                break
            }
        }
    }

    // MARK: - Visual Drag (CALayer bitmap snapshots)

    private func beginVisualDrag(tabId: String, mousePoint: NSPoint) {
        isDragging = true
        layer?.masksToBounds = false

        guard let draggedIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        var tabLayers: [String: CALayer] = [:]
        var dragOffset: CGFloat = 0
        var draggedLayer: CALayer!
        let scale = window?.backingScaleFactor ?? 2.0

        // Compute tab area X
        var tabAreaX: CGFloat = canClose ? paneButtonWidth : 0
        tabAreaX += paneButtonWidth

        let tabAreaWidth = bounds.width - tabAreaX - addButtonWidth
        let count = CGFloat(tabs.count)
        let totalPadding = tabPadding * (count - 1) + tabPadding * 2
        let tabWidth = max(40, (tabAreaWidth - totalPadding) / count)

        for tabView in tabItemViews {
            let id = tabView.tabId
            let frameInBar = tabView.frame

            guard let bitmapRep = tabView.bitmapImageRepForCachingDisplay(in: tabView.bounds) else { continue }
            tabView.cacheDisplay(in: tabView.bounds, to: bitmapRep)

            let layer = CALayer()
            layer.frame = frameInBar
            layer.contents = bitmapRep.cgImage
            layer.contentsScale = scale
            layer.contentsGravity = .resizeAspectFill
            layer.cornerRadius = 6

            if id == tabId {
                layer.zPosition = 100
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.3
                layer.shadowRadius = 8
                layer.shadowOffset = CGSize(width: 0, height: -2)
                draggedLayer = layer

                let mouseInBar = self.convert(mousePoint, from: nil)
                dragOffset = mouseInBar.x - frameInBar.minX
            } else {
                layer.zPosition = 0
            }

            tabLayers[id] = layer
            self.layer?.addSublayer(layer)
        }

        for tabView in tabItemViews {
            tabView.alphaValue = 0
        }

        dragState = DragState(
            draggedTabId: tabId,
            currentIndex: draggedIndex,
            draggedLayer: draggedLayer,
            tabLayers: tabLayers,
            tabWidth: tabWidth,
            tabAreaX: tabAreaX,
            dragOffset: dragOffset
        )
    }

    private func updateVisualDrag(windowPoint: NSPoint) {
        guard var state = dragState else { return }

        let localPoint = self.convert(windowPoint, from: nil)

        // Move dragged layer
        var targetX = localPoint.x - state.dragOffset
        let maxX = bounds.width - addButtonWidth - state.tabWidth
        targetX = max(state.tabAreaX, min(targetX, maxX))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        state.draggedLayer.frame.origin.x = targetX
        CATransaction.commit()

        // Compute insertion index
        let nonDraggedIds = tabs.map(\.id).filter { $0 != state.draggedTabId }
        let cursorX = localPoint.x

        var newIndex = nonDraggedIds.count
        for (i, id) in nonDraggedIds.enumerated() {
            guard let layer = state.tabLayers[id] else { continue }
            if cursorX < layer.frame.midX {
                newIndex = i
                break
            }
        }

        if newIndex != state.currentIndex {
            state.currentIndex = newIndex
            dragState = state
            animateTabLayers(state: state)
        } else {
            dragState = state
        }
    }

    private func animateTabLayers(state: DragState) {
        let draggedId = state.draggedTabId
        let nonDraggedIds = tabs.map(\.id).filter { $0 != draggedId }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        var x: CGFloat = state.tabAreaX + tabPadding
        for (i, id) in nonDraggedIds.enumerated() {
            if i == state.currentIndex {
                x += state.tabWidth + tabPadding
            }
            if let layer = state.tabLayers[id] {
                layer.frame = CGRect(x: x, y: tabVerticalInset,
                                     width: state.tabWidth,
                                     height: barHeight - tabVerticalInset * 2)
                x += state.tabWidth + tabPadding
            }
        }

        CATransaction.commit()
    }

    private func endVisualDrag() {
        guard let state = dragState else {
            isDragging = false
            return
        }

        let targetX = state.tabAreaX + tabPadding + CGFloat(state.currentIndex) * (state.tabWidth + tabPadding)
        let targetFrame = CGRect(x: targetX, y: tabVerticalInset,
                                 width: state.tabWidth,
                                 height: barHeight - tabVerticalInset * 2)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            self?.finalizeDrag(state: state)
        }

        state.draggedLayer.shadowOpacity = 0
        state.draggedLayer.frame = targetFrame

        CATransaction.commit()
    }

    private func finalizeDrag(state: DragState) {
        for (_, layer) in state.tabLayers {
            layer.removeFromSuperlayer()
        }
        for tabView in tabItemViews {
            tabView.alphaValue = 1
        }

        var reordered = tabs.filter { $0.id != state.draggedTabId }
        if let draggedTab = tabs.first(where: { $0.id == state.draggedTabId }) {
            let insertAt = min(state.currentIndex, reordered.count)
            reordered.insert(draggedTab, at: insertAt)
        }

        dragState = nil
        isDragging = false

        onReorderTabs?(reordered.map(\.id))
    }

    // MARK: - Context Menu

    private func showContextMenu(tabId: String) {
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

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onCloseTab?(tabId)
    }

    @objc private func contextCloseOthers(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.closeOtherTabs(exceptId: tabId)
    }

    @objc private func contextCloseRight(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.closeTabsToRight(ofId: tabId)
    }

    @objc private func contextDuplicate(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.duplicateTab(id: tabId)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onDoubleClickTab?(tabId)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Bar background
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Bottom border
        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        borderPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        borderPath.stroke()

        // Focused indicator: thin accent color top line
        if isFocused {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1.5).fill()
        }
    }
}

// MARK: - Pill Tab Item View

private class PillTabItemView: NSView {

    let tabId: String
    let isActive: Bool
    var onMouseDown: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dirtyDot = NSView()
    private let isDirty: Bool
    private let isExecuting: Bool
    private var isHovered = false
    private var spinner: NSProgressIndicator?

    init(tab: QueryTab, isActive: Bool) {
        self.tabId = tab.id
        self.isActive = isActive
        self.isDirty = tab.isDirty
        self.isExecuting = tab.isExecuting
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = tab.name

        // Label
        label.stringValue = tab.name
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        // Close button
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?.withSymbolConfiguration(closeConfig)
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isHidden = !isActive && !tab.isDirty

        // Dirty dot
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.isHidden = !tab.isDirty || isActive

        // Executing spinner
        if tab.isExecuting {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.translatesAutoresizingMaskIntoConstraints = false
            spin.startAnimation(nil)
            addSubview(spin)
            self.spinner = spin
            closeButton.isHidden = true
            dirtyDot.isHidden = true
        }

        addSubview(label)
        addSubview(closeButton)
        addSubview(dirtyDot)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            dirtyDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])

        if let spin = spinner {
            NSLayoutConstraint.activate([
                spin.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                spin.centerYAnchor.constraint(equalTo: centerYAnchor),
                spin.widthAnchor.constraint(equalToConstant: 12),
                spin.heightAnchor.constraint(equalToConstant: 12),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isActive {
            // Active pill: filled background
            NSColor.textBackgroundColor.setFill()
            let pillPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            pillPath.fill()
        } else if isHovered {
            // Hover: subtle fill
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            let pillPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            pillPath.fill()
        }
        // Inactive, not hovered: transparent (bar background shows through)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelectTab()
        onContextMenu?()
    }

    private func onSelectTab() {
        // Bubble up selection through the parent's callback
        if let paneTabBar = superview as? PaneTabBar {
            paneTabBar.onSelectTab?(tabId)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        if !isExecuting {
            closeButton.isHidden = false
            dirtyDot.isHidden = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        if !isExecuting {
            closeButton.isHidden = !isActive && !isDirty
            dirtyDot.isHidden = !isDirty || isActive
        }
    }

    @objc private func closeTapped() { onClose?() }
}
