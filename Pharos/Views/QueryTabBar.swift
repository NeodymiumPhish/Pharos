import AppKit
import Combine

/// Custom tab bar view showing open query tabs with Safari-style drag-reorder.
///
/// Drag-to-reorder uses CALayer bitmap snapshots for smooth visual feedback:
/// the dragged tab floats with a shadow following the cursor, while other tabs
/// animate to show the drop position. Uses `NSWindow.trackEvents` for reliable
/// modal mouse tracking.
class QueryTabBar: NSView {

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onDoubleClickTab: ((String) -> Void)?

    private var tabs: [QueryTab] = []
    private var activeTabId: String?
    private var pinnedTabId: String?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let newTabButton = NSButton()

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Drag State

    private var isDragging = false
    private var dragState: DragState?

    private struct DragState {
        let draggedTabId: String
        var currentIndex: Int
        let draggedLayer: CALayer
        let tabLayers: [String: CALayer]
        let tabWidths: [String: CGFloat]
        let barHeight: CGFloat
        let dragOffset: CGFloat
    }

    // MARK: - Init

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
            .combineLatest(stateManager.$activeTabId, stateManager.$pinnedTabId)
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs, activeId, pinnedId in
                self?.tabs = tabs
                self?.activeTabId = activeId
                self?.pinnedTabId = pinnedId
                self?.rebuildTabs()
            }
            .store(in: &cancellables)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    // MARK: - Rebuild

    private func rebuildTabs() {
        guard !isDragging else { return }

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, tab) in tabs.enumerated() {
            let tabView = TabItemView(tab: tab, isActive: tab.id == activeTabId, isPinnedSource: tab.id == pinnedTabId)
            tabView.onMouseDown = { [weak self] event in
                self?.handleTabMouseDown(event: event, tabId: tab.id)
            }
            tabView.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            tabView.onContextMenu = { [weak self] in self?.showContextMenu(tabId: tab.id, index: index) }
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

    // MARK: - Unified Mouse Handling

    /// Handles all left-click interactions on a tab: click, double-click, or drag.
    /// Uses NSWindow.trackEvents for a modal tracking loop that blocks until mouseUp.
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
                    if dx < 5 { return } // Threshold not crossed yet
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

    // MARK: - Visual Drag: Begin

    private func beginVisualDrag(tabId: String, mousePoint: NSPoint) {
        isDragging = true
        self.layer?.masksToBounds = false

        guard let draggedIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        var tabLayers: [String: CALayer] = [:]
        var tabWidths: [String: CGFloat] = [:]
        var dragOffset: CGFloat = 0
        var draggedLayer: CALayer!

        let scale = window?.backingScaleFactor ?? 2.0

        for arrangedView in stackView.arrangedSubviews {
            guard let tabView = arrangedView as? TabItemView else { continue }
            let id = tabView.tabId

            // Convert frame to QueryTabBar coordinate space
            let frameInBar = self.convert(tabView.bounds, from: tabView)
            tabWidths[id] = frameInBar.width

            // Create bitmap snapshot
            guard let bitmapRep = tabView.bitmapImageRepForCachingDisplay(in: tabView.bounds) else { continue }
            tabView.cacheDisplay(in: tabView.bounds, to: bitmapRep)

            let layer = CALayer()
            layer.frame = frameInBar
            layer.contents = bitmapRep.cgImage
            layer.contentsScale = scale
            layer.contentsGravity = .resizeAspectFill

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

        // Hide real views
        for arrangedView in stackView.arrangedSubviews {
            arrangedView.alphaValue = 0
        }

        dragState = DragState(
            draggedTabId: tabId,
            currentIndex: draggedIndex,
            draggedLayer: draggedLayer,
            tabLayers: tabLayers,
            tabWidths: tabWidths,
            barHeight: bounds.height,
            dragOffset: dragOffset
        )
    }

    // MARK: - Visual Drag: Update

    private func updateVisualDrag(windowPoint: NSPoint) {
        guard var state = dragState else { return }

        let localPoint = self.convert(windowPoint, from: nil)

        // 1. Move dragged layer to follow cursor (instant, no animation)
        let draggedWidth = state.draggedLayer.bounds.width
        var targetX = localPoint.x - state.dragOffset
        targetX = max(0, min(targetX, bounds.width - draggedWidth))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        state.draggedLayer.frame.origin.x = targetX
        CATransaction.commit()

        // 2. Compute insertion index from cursor position relative to non-dragged tab midpoints
        let nonDraggedIds = tabs.map(\.id).filter { $0 != state.draggedTabId }
        let cursorX = localPoint.x

        // Build current positions of non-dragged layers
        var newIndex = nonDraggedIds.count // Default: insert at end
        for (i, id) in nonDraggedIds.enumerated() {
            guard let layer = state.tabLayers[id] else { continue }
            if cursorX < layer.frame.midX {
                newIndex = i
                break
            }
        }

        // 3. If insertion index changed, animate non-dragged layers to new positions
        if newIndex != state.currentIndex {
            state.currentIndex = newIndex
            dragState = state
            animateTabLayers(state: state)
        } else {
            dragState = state
        }
    }

    /// Animate non-dragged tab layers to positions that leave a gap at `currentIndex`.
    private func animateTabLayers(state: DragState) {
        let draggedId = state.draggedTabId
        let nonDraggedIds = tabs.map(\.id).filter { $0 != draggedId }
        let gapWidth = state.tabWidths[draggedId] ?? 0

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        var x: CGFloat = 0
        for (i, id) in nonDraggedIds.enumerated() {
            if i == state.currentIndex {
                x += gapWidth
            }
            if let layer = state.tabLayers[id], let width = state.tabWidths[id] {
                layer.frame = CGRect(x: x, y: layer.frame.origin.y, width: width, height: state.barHeight)
                x += width
            }
        }
        // If inserting at the end
        if state.currentIndex >= nonDraggedIds.count {
            // Gap is at the end — already handled by the loop ending
        }

        CATransaction.commit()
    }

    // MARK: - Visual Drag: End

    private func endVisualDrag() {
        guard let state = dragState else {
            isDragging = false
            return
        }

        // Compute the frame where the dragged tab should land
        let targetFrame = computeDropFrame(state: state)

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

    /// Calculate the frame where the dragged tab should snap to on drop.
    private func computeDropFrame(state: DragState) -> CGRect {
        let draggedId = state.draggedTabId
        let nonDraggedIds = tabs.map(\.id).filter { $0 != draggedId }
        let draggedWidth = state.tabWidths[draggedId] ?? 0

        var x: CGFloat = 0
        for (i, id) in nonDraggedIds.enumerated() {
            if i == state.currentIndex {
                return CGRect(x: x, y: 0, width: draggedWidth, height: state.barHeight)
            }
            x += state.tabWidths[id] ?? 0
        }
        // Inserting at the end
        return CGRect(x: x, y: 0, width: draggedWidth, height: state.barHeight)
    }

    /// Remove all snapshot layers, restore real views, commit the new tab order.
    private func finalizeDrag(state: DragState) {
        // Remove all snapshot layers
        for (_, layer) in state.tabLayers {
            layer.removeFromSuperlayer()
        }

        // Restore real view visibility
        for arrangedView in stackView.arrangedSubviews {
            arrangedView.alphaValue = 1
        }

        // Build the new tab order: move dragged tab to currentIndex
        var reordered = tabs.filter { $0.id != state.draggedTabId }
        if let draggedTab = tabs.first(where: { $0.id == state.draggedTabId }) {
            let insertAt = min(state.currentIndex, reordered.count)
            reordered.insert(draggedTab, at: insertAt)
        }

        // Clear drag state BEFORE committing — the Combine pipeline
        // calls rebuildTabs() synchronously and it guards on isDragging
        dragState = nil
        isDragging = false

        stateManager.tabs = reordered
    }

    // MARK: - Context Menu

    private func showContextMenu(tabId: String, index: Int) {
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
        closeRightItem.isEnabled = index < tabs.count - 1
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
        stateManager.closeOtherTabs(exceptId: tabId)
    }

    @objc private func contextCloseRight(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        stateManager.closeTabsToRight(ofId: tabId)
    }

    @objc private func contextDuplicate(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        stateManager.duplicateTab(id: tabId)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onDoubleClickTab?(tabId)
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
    var onMouseDown: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dirtyDot = NSView()
    private let isActive: Bool
    private let isPinnedSource: Bool

    init(tab: QueryTab, isActive: Bool, isPinnedSource: Bool = false) {
        self.tabId = tab.id
        self.isActive = isActive
        self.isPinnedSource = isPinnedSource
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
        } else if isPinnedSource {
            NSColor.systemOrange.withAlphaComponent(0.08).setFill()
            bounds.fill()

            // Orange bottom bar for pinned source
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }

        // Right separator
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - 0.5, y: 4))
        path.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY - 4))
        path.stroke()
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        // Forward to QueryTabBar for unified click/drag handling.
        // The trackEvents loop in QueryTabBar blocks until mouseUp.
        onMouseDown?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Select the tab first, then show context menu
        AppStateManager.shared.activeTabId = tabId
        onContextMenu?()
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

    @objc private func closeTapped() { onClose?() }
}
