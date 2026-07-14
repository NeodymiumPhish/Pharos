import AppKit

/// A virtualized checklist of string values with a leading "(Select All)" row.
/// Self-contained: knows nothing about filters or the grid. Reports the checked
/// set and notifies on change. Search filters which rows are visible without
/// altering hidden rows' checked state.
final class FilterValueListView: NSView {

    /// Fired whenever the checked set changes (row toggle or Select All).
    /// Integrators should capture `[weak self]` to avoid a retain cycle if the
    /// owner of this view also owns the closure.
    var onSelectionChanged: (() -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var allValues: [String] = []       // full model (post setValues)
    private var visibleValues: [String] = []    // currently shown (post search)
    private var checked: Set<String> = []
    private var searchQuery: String = ""
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = heightAnchor.constraint(equalToConstant: FilterPopoverSizing.defaultListHeight)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    /// Current fixed height of the list.
    var listHeight: CGFloat { heightConstraint.constant }

    /// Set the list's fixed height. Caller is responsible for clamping.
    func setListHeight(_ h: CGFloat) { heightConstraint.constant = h }

    /// Widest rendered width across the full (pre-search) value set, using the
    /// given font. Accounts for the "(Blanks)" display label. Returns 0 if empty.
    func maxValueWidth(font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for value in allValues {
            let w = (displayLabel(for: value) as NSString).size(withAttributes: attrs).width
            if w > widest { widest = w }
        }
        return widest
    }

    /// Replace the list contents and the initial checked set.
    func setValues(_ values: [String], checked: Set<String>) {
        self.allValues = values
        self.checked = checked
        applySearch(searchQuery)
    }

    /// Checked values (excludes the synthetic Select All row).
    var checkedValues: Set<String> { checked }

    /// Filter which rows are visible (case-insensitive substring). Hidden rows
    /// keep their checked state.
    func applySearch(_ query: String) {
        searchQuery = query
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            visibleValues = allValues
        } else {
            visibleValues = allValues.filter { displayLabel(for: $0).lowercased().contains(q) }
        }
        tableView.reloadData()
    }

    private func displayLabel(for value: String) -> String {
        value == ColumnFilter.blanksSentinel ? "(Blanks)" : value
    }

    /// Aggregate state of the Select All row over the currently visible rows.
    private var selectAllState: NSControl.StateValue {
        if visibleValues.isEmpty { return .off }
        let checkedCount = visibleValues.reduce(0) { $0 + (checked.contains($1) ? 1 : 0) }
        if checkedCount == 0 { return .off }
        if checkedCount == visibleValues.count { return .on }
        return .mixed
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = sender.tag
        if row == 0 {
            // Select All toggles only the VISIBLE rows; check all unless already all-on.
            if selectAllState == .on {
                checked.subtract(visibleValues)
            } else {
                checked.formUnion(visibleValues)
            }
            tableView.reloadData()   // every visible row's checkbox changes
        } else {
            guard row - 1 < visibleValues.count else { return }   // stale tag guard
            let value = visibleValues[row - 1]
            if sender.state == .on { checked.insert(value) } else { checked.remove(value) }
            // The clicked checkbox already shows the right state; only the
            // Select All row's tri-state needs refreshing. Avoids a full reload
            // (which would steal focus from the checkbox mid-interaction).
            tableView.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
        }
        onSelectionChanged?()
    }
}

extension FilterValueListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleValues.count + 1   // +1 for the Select All row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("checkRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
            ?? NSButton(checkboxWithTitle: "", target: nil, action: nil)
        cell.identifier = id
        cell.lineBreakMode = .byTruncatingTail
        cell.target = self
        cell.action = #selector(toggleRow(_:))
        cell.tag = row

        if row == 0 {
            cell.title = "(Select All)"
            cell.font = .systemFont(ofSize: 12, weight: .medium)
            cell.allowsMixedState = true
            cell.state = selectAllState
            cell.isEnabled = !visibleValues.isEmpty
            cell.toolTip = nil
        } else {
            let value = visibleValues[row - 1]
            let label = displayLabel(for: value)
            cell.title = label
            cell.font = .systemFont(ofSize: 12)
            cell.allowsMixedState = false
            cell.state = checked.contains(value) ? .on : .off
            cell.isEnabled = true
            cell.toolTip = label
        }
        return cell
    }
}
