import AppKit

/// The leading part of a query tab's context row: the tab's connection ›
/// schema, what the connection is doing, and the transaction chip.
///
/// These change only this tab, so they sit in the tab's pane, not in the
/// window toolbar (HIG, Tab views: "Make sure the controls within a pane
/// affect content only in the same pane"). The connection is a pop-up button
/// — one choice from a flat list — and Connect is a separate button beside it
/// (HIG, Pop-up buttons: actions go in a pull-down, not a pop-up).
///
/// A view only: it shows what it is given and reports clicks through closures.
final class TabContextBar: NSView {

    struct ConnectionItem: Equatable {
        let id: String
        let name: String
        let state: TabConnectionState
    }

    let connectionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let schemaButton = SchemaPopUpButton(frame: .zero, pullsDown: false)
    let stateLabel = NSTextField(labelWithString: "")
    let stateButton = NSButton()
    let spinner = NSProgressIndicator()
    let transactionChip = NSButton()
    private let separatorLabel = NSTextField(labelWithString: "›")

    var onChooseConnection: ((String) -> Void)?
    var onManageConnections: (() -> Void)?
    var onConnect: (() -> Void)?
    var onSchema: ((SchemaPopUpButton) -> Void)?
    /// The chip's menu, built by the owner each time it opens.
    var transactionMenu: (() -> NSMenu?)?

    private static let chooseTag = -1
    private static let manageTag = -2
    private var selectedConnectionId: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build() {
        connectionPopUp.target = self
        connectionPopUp.action = #selector(connectionChosen(_:))
        connectionPopUp.setAccessibilityLabel(String(localized: "Connection"))
        connectionPopUp.setAccessibilityIdentifier("editor.context.connection")
        connectionPopUp.toolTip = String(localized: "This tab's database connection")

        schemaButton.addItem(withTitle: "")
        schemaButton.onActivate = { [weak self] button in self?.onSchema?(button) }
        schemaButton.setAccessibilityLabel(String(localized: "Schema"))
        schemaButton.setAccessibilityIdentifier("editor.context.schema")
        schemaButton.toolTip = String(localized: "This tab's schema")

        separatorLabel.textColor = .tertiaryLabelColor
        separatorLabel.setAccessibilityElement(false)

        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        stateLabel.setAccessibilityIdentifier("editor.context.state")

        stateButton.bezelStyle = .push
        stateButton.controlSize = .small
        stateButton.target = self
        stateButton.action = #selector(connectPressed)
        stateButton.setAccessibilityIdentifier("editor.context.connect")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        transactionChip.bezelStyle = .push
        transactionChip.controlSize = .small
        transactionChip.imagePosition = .imageLeading
        transactionChip.target = self
        transactionChip.action = #selector(chipPressed)
        transactionChip.setAccessibilityIdentifier("editor.context.transaction")
        transactionChip.isHidden = true

        for popUp in [connectionPopUp, schemaButton as NSPopUpButton] {
            popUp.bezelStyle = .push
            popUp.controlSize = .regular
            popUp.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        }

        let row = NSStackView(views: [connectionPopUp, separatorLabel, schemaButton, spinner, stateLabel,
                                      stateButton, transactionChip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(10, after: schemaButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            connectionPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            connectionPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            schemaButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            schemaButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
    }

    // MARK: - Showing

    /// The connections, the tab's one selected. With none selected, a
    /// "Choose Connection" item heads the list and shows in the button.
    func showConnections(_ items: [ConnectionItem], selectedId: String?) {
        selectedConnectionId = selectedId
        connectionPopUp.removeAllItems()
        let menu = connectionPopUp.menu ?? NSMenu()
        menu.autoenablesItems = false
        if selectedId == nil || !items.contains(where: { $0.id == selectedId }) {
            let choose = NSMenuItem(title: String(localized: "Choose Connection"), action: nil, keyEquivalent: "")
            choose.tag = Self.chooseTag
            choose.isEnabled = false
            choose.image = Self.dot(.none)
            menu.addItem(choose)
        }
        for item in items {
            let menuItem = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
            menuItem.representedObject = item.id
            menuItem.image = Self.dot(item.state)
            // The state in words as well as colour (Differentiate Without
            // Color, VoiceOver).
            menuItem.subtitle = item.state.label
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: String(localized: "Manage Connections…"), action: nil, keyEquivalent: "")
        manage.tag = Self.manageTag
        menu.addItem(manage)
        selectCurrent()
    }

    func showSchema(title: String, isEnabled: Bool) {
        schemaButton.item(at: 0)?.title = title
        schemaButton.isEnabled = isEnabled
        schemaButton.setAccessibilityValue(title)
    }

    func showState(_ state: TabContextState) {
        stateLabel.stringValue = state.text
        stateLabel.toolTip = state.toolTip
        if let title = state.buttonTitle {
            stateButton.title = title
            stateButton.toolTip = state.toolTip
            stateButton.isHidden = false
        } else {
            stateButton.isHidden = true
        }
        if state.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // "Choose a database for this tab." stands alone: no schema to pick.
        let hasConnection = state != .chooseConnection
        separatorLabel.isHidden = !hasConnection
        schemaButton.isHidden = !hasConnection
    }

    func showTransaction(_ state: TabSessionBannerState?) {
        guard let state else {
            transactionChip.isHidden = true
            return
        }
        let (symbol, tint): (String, NSColor) = {
            switch state {
            case .transaction: return ("arrow.triangle.branch", .systemOrange)
            case .failed: return ("exclamationmark.octagon.fill", .systemRed)
            case .reset: return ("arrow.clockwise.circle", .secondaryLabelColor)
            }
        }()
        transactionChip.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        transactionChip.contentTintColor = tint
        transactionChip.title = state.chipTitle
        transactionChip.toolTip = state.message
        transactionChip.setAccessibilityLabel(state.chipTitle)
        transactionChip.setAccessibilityHelp(state.message)
        transactionChip.isHidden = false
    }

    // MARK: - Actions

    @objc private func connectionChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if item.tag == Self.manageTag {
            selectCurrent()
            onManageConnections?()
            return
        }
        guard let id = item.representedObject as? String else { return }
        // The button keeps showing the tab's connection until the owner has
        // moved the tab (it may ask first, and the user may cancel).
        selectCurrent()
        if id != selectedConnectionId { onChooseConnection?(id) }
    }

    private func selectCurrent() {
        if let id = selectedConnectionId,
           let index = connectionPopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            connectionPopUp.selectItem(at: index)
        } else {
            connectionPopUp.selectItem(withTag: Self.chooseTag)
        }
    }

    @objc private func connectPressed() { onConnect?() }

    @objc private func chipPressed() {
        guard let menu = transactionMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: transactionChip.bounds.maxY + 2), in: transactionChip)
    }

    /// A small dot in the connection state's colour, an empty ring when not
    /// connected — the same marks as the native tab.
    static func dot(_ state: TabConnectionState) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = rect.insetBy(dx: 1.5, dy: 1.5)
            if let fill = state.fill {
                fill.setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1.2
                NSColor.tertiaryLabelColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.accessibilityDescription = state.label
        return image
    }
}
