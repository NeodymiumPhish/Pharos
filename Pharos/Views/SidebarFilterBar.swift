import AppKit

/// The bar across the BOTTOM of the sidebar: a leading "+" pull-down that
/// adds things to the navigator that can hold them, and a filter field.
/// Xcode puts its filter here rather than at the top, and so does this.
///
/// The "+" is a pull-down `NSPopUpButton`. Its image has to live on
/// `menu.items[0]` — the hidden title item — or the button draws the first
/// real item's title instead of the glyph. `.accessoryBarAction` plus
/// `showsBorderOnlyWhileMouseInside` gives it the same flat treatment the
/// navigator selector's buttons have.
final class SidebarFilterBar: NSView {

    /// Height of the bar.
    static let height: CGFloat = 28

    // MARK: - Actions

    /// "+" ▸ New Query.
    var onNewQuery: (() -> Void)?
    /// "+" ▸ New Folder.
    var onNewFolder: (() -> Void)?
    /// Every keystroke in the filter field (the field sends immediately; the
    /// owner debounces).
    var onTextChanged: ((String) -> Void)?

    // MARK: - Views

    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let filterField = NSSearchField()
    /// Reserved for scope toggles. Empty and zero-width today; it exists so
    /// adding one later does not move the field.
    private let trailingSlot = NSView()
    private let stack = NSStackView()

    /// Whether the "+" pull-down is on screen. Only the Query Library can
    /// create things, so only it shows one; the stack closes the gap.
    var showsAddButton: Bool = true {
        didSet { addButton.isHidden = !showsAddButton }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        buildAddButton()
        buildFilterField()

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.widthAnchor.constraint(equalToConstant: 0).isActive = true

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(addButton)
        stack.addArrangedSubview(filterField)
        stack.addArrangedSubview(trailingSlot)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    private func buildAddButton() {
        addButton.bezelStyle = .accessoryBarAction
        addButton.showsBorderOnlyWhileMouseInside = true
        addButton.imagePosition = .imageOnly
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setAccessibilityLabel(String(localized: "Add"))
        addButton.setAccessibilityIdentifier("sidebar.filter.add")
        addButton.toolTip = String(localized: "Add")

        let menu = NSMenu()
        // Item 0 of a pull-down is the (hidden) title item and is what the
        // button draws. The glyph goes here, not on the real items.
        let titleItem = NSMenuItem()
        titleItem.image = NSImage(systemSymbolName: "plus",
                                  accessibilityDescription: String(localized: "Add"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        menu.addItem(titleItem)

        let newQuery = NSMenuItem(title: String(localized: "New Query"),
                                  action: #selector(newQueryChosen), keyEquivalent: "")
        newQuery.target = self
        menu.addItem(newQuery)

        let newFolder = NSMenuItem(title: String(localized: "New Folder"),
                                   action: #selector(newFolderChosen), keyEquivalent: "")
        newFolder.target = self
        menu.addItem(newFolder)

        addButton.menu = menu
        (addButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func buildFilterField() {
        filterField.controlSize = .regular
        filterField.placeholderString = String(localized: "Filter")
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterFieldChanged(_:))
        filterField.setAccessibilityIdentifier("sidebar.filter.field")

        // The funnel, not the magnifier: this narrows what is already listed,
        // it does not search elsewhere. Swapping the cell's image in place
        // keeps the cancel button, which replacing the cell would lose.
        let funnel = NSImage(systemSymbolName: "line.3.horizontal.decrease",
                             accessibilityDescription: String(localized: "Filter"))
        (filterField.cell as? NSSearchFieldCell)?.searchButtonCell?.image = funnel

        // No width constraint, and a low compression resistance: the sidebar's
        // fitting width feeds its split-view pane, and a field that refuses to
        // shrink would push the pane's minimum out with it.
        filterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    }

    // MARK: - Focus

    /// Put the caret in the filter field (View ▸ Filter in Navigator).
    func focus() {
        window?.makeFirstResponder(filterField)
    }

    // MARK: - Actions

    @objc private func newQueryChosen() { onNewQuery?() }
    @objc private func newFolderChosen() { onNewFolder?() }

    @objc private func filterFieldChanged(_ sender: NSSearchField) {
        onTextChanged?(sender.stringValue)
    }
}
