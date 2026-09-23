import AppKit

/// The bar across the BOTTOM of the sidebar: a leading "+" that adds things
/// to the navigator that can hold them, and a filter field. Xcode puts its
/// filter here rather than at the top, and so does this.
///
/// The Query Library's "+" is a pull-down `NSPopUpButton` (New Query, New
/// Folder). Its image has to live on `menu.items[0]` — the hidden title item —
/// or the button draws the first real item's title instead of the glyph. The
/// Variables navigator can make only one thing, so its "+" is a plain button
/// that makes it: a one-item menu is a click with nothing to choose.
/// `.accessoryBarAction` plus `showsBorderOnlyWhileMouseInside` gives both the
/// same flat treatment the navigator selector's buttons have.
final class SidebarFilterBar: NSView {

    /// Height of the bar.
    static let height: CGFloat = 28

    // MARK: - Actions

    /// "+" ▸ New Query.
    var onNewQuery: (() -> Void)?
    /// "+" ▸ New Folder.
    var onNewFolder: (() -> Void)?
    /// "+" in the Variables navigator (New Variable).
    var onNewVariable: (() -> Void)?
    /// Every keystroke in the filter field (the field sends immediately; the
    /// owner debounces).
    var onTextChanged: ((String) -> Void)?

    // MARK: - Views

    /// The Query Library's "+" pull-down.
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The Variables navigator's "+", which makes a variable at once.
    let newVariableButton = NSButton()
    let filterField = NSSearchField()
    /// Reserved for scope toggles. Empty and zero-width today; it exists so
    /// adding one later does not move the field.
    private let trailingSlot = NSView()
    private let stack = NSStackView()

    /// Show the "+" that belongs to `navigator`. Only the Query Library and
    /// the Variables navigator can create things, so the others show none;
    /// the stack closes the gap.
    func configureAddControl(for navigator: Navigator) {
        addButton.isHidden = (navigator != .library)
        newVariableButton.isHidden = (navigator != .variables)
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
        buildNewVariableButton()
        buildFilterField()

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.widthAnchor.constraint(equalToConstant: 0).isActive = true

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(addButton)
        stack.addArrangedSubview(newVariableButton)
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
        titleItem.image = Self.plusImage(accessibilityDescription: String(localized: "Add"))
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
        addButton.widthAnchor.constraint(equalToConstant: Self.addControlWidth).isActive = true
    }

    private func buildNewVariableButton() {
        newVariableButton.bezelStyle = .accessoryBarAction
        newVariableButton.showsBorderOnlyWhileMouseInside = true
        newVariableButton.imagePosition = .imageOnly
        newVariableButton.image = Self.plusImage(accessibilityDescription: String(localized: "New Variable"))
        newVariableButton.translatesAutoresizingMaskIntoConstraints = false
        newVariableButton.setAccessibilityLabel(String(localized: "New Variable"))
        newVariableButton.setAccessibilityIdentifier("sidebar.filter.newVariable")
        newVariableButton.toolTip = String(localized: "New Variable")
        newVariableButton.target = self
        newVariableButton.action = #selector(newVariableChosen)
        newVariableButton.isHidden = true
        newVariableButton.widthAnchor.constraint(equalToConstant: Self.addControlWidth).isActive = true
    }

    /// Width of either "+" control.
    private static let addControlWidth: CGFloat = 28

    /// The "+" glyph both add controls draw, so switching navigators does not
    /// change its size. 14 pt: at 12 it was easy to miss.
    private static func plusImage(accessibilityDescription: String) -> NSImage? {
        NSImage(systemSymbolName: "plus", accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
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
    @objc private func newVariableChosen() { onNewVariable?() }

    @objc private func filterFieldChanged(_ sender: NSSearchField) {
        onTextChanged?(sender.stringValue)
    }
}
