import AppKit

/// The Variable Manager window's content: the app-wide query variables as a
/// list (left) and the selected variable's detail (right): name, type and
/// value (`VariableDetailVC`), and the connections it applies to
/// (`VariableConnectionsView`).
///
/// Host-agnostic, like the sidebar panel it replaced: the list comes in through
/// `setVariables`, every edit goes out through `onChange`, and the connection
/// choices come from `choicesProvider`. The rules are the panel's: a name edit
/// commits at a settle point (another row, the window closing), a duplicate
/// name is refused, and a row left empty in name and value is dropped.
final class VariableManagerVC: NSViewController {

    var onChange: (([QueryVariable]) -> Void)?
    /// The connections a variable can be linked to, with names and tiles.
    var choicesProvider: (QueryVariable) -> [VariableConnectionsView.Choice] = { _ in [] }

    private(set) var variables: [QueryVariable] = []
    private(set) var selectedId: UUID?
    private var filterText = ""

    private let listView = VariableListView()
    private let searchField = NSSearchField()
    private let detailArea = NSView()
    private let emptyState = EmptyStateView()
    let connectionsView = VariableConnectionsView()
    private(set) var detailVC: VariableDetailVC?

    // MARK: - Input

    /// Adopt `vars` (the first load, or another window's edit). A pending
    /// rename in the detail pane settles onto the incoming list first; the
    /// selection stays when its variable is still there.
    func setVariables(_ vars: [QueryVariable]) {
        guard vars != variables else { return }
        let keep = selectedId
        closeDetail()
        variables = vars
        refreshList()
        if let keep, variables.contains(where: { $0.id == keep }) { showDetail(for: keep) } else { showEmptyState() }
    }

    /// Commit a pending rename (the window is closing), and drop an abandoned
    /// empty row.
    func settlePendingEdit() {
        guard let detail = detailVC else { return }
        detail.settleForDismissal()
        pruneIfAbandoned(detail.variable)
    }

    /// The connections changed (a record saved, removed, connected): rebuild
    /// the choices for the variable on screen.
    func refreshChoices() {
        guard let id = selectedId, let variable = variables.first(where: { $0.id == id }) else { return }
        connectionsView.show(choices: choicesProvider(variable), linked: variable.connectionIds)
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        view = root

        searchField.placeholderString = String(localized: "Filter")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("variables.manager.filter")

        listView.onAdd = { [weak self] in self?.addVariable() }
        listView.onSelect = { [weak self] id in self?.select(id) }
        listView.onDelete = { [weak self] id in self?.deleteVariable(id) }
        listView.scopeText = { variable in
            variable.isGlobal
                ? String(localized: "All connections")
                : String(localized: "\(variable.connectionIds.count) connection(s)",
                         comment: "How many connections a variable is linked to.")
        }

        let left = NSStackView(views: [searchField, listView])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)

        connectionsView.onChange = { [weak self] ids in self?.connectionsChanged(ids) }
        emptyState.show(symbol: "curlybraces", title: String(localized: "No Variable Selected"),
                        message: String(localized: "Select a variable, or click + to add one."))

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detailArea)
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        for v in [searchField, listView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -16).isActive = true
        }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        detailArea.addSubview(emptyState)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            detailArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 621),
            emptyState.topAnchor.constraint(equalTo: detailArea.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: detailArea.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: detailArea.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: detailArea.bottomAnchor),
        ])
        refreshList()
        showEmptyState()
    }

    // MARK: - Selection

    func select(_ id: UUID) {
        guard id != selectedId else { return }
        if let detail = detailVC {
            // Leaving a row is a settle point; a colliding name refuses to go.
            guard !detail.isNameCollision else {
                detail.focusNameField()
                return
            }
            detail.settleForDismissal()
            let leaving = detail.variable
            closeDetail()
            pruneIfAbandoned(leaving)
        }
        guard variables.contains(where: { $0.id == id }) else { showEmptyState(); return }
        showDetail(for: id)
        refreshList()
    }

    private func showDetail(for id: UUID) {
        guard let variable = variables.first(where: { $0.id == id }) else { return }
        let detail = VariableDetailVC(variable: variable)
        detail.showsBackButton = false
        detail.onChange = { [weak self] updated in self?.variableEdited(updated) }
        detail.onDelete = { [weak self] in self?.deleteVariable(id) }
        detail.onBack = { [weak self] in self?.settlePendingEdit() }
        addChild(detail)
        detailVC = detail
        selectedId = id
        listView.selectedId = id

        // The value on the left, its connections on the right of a vertical
        // divider (owner, 2026-10-22): both get the pane's full height, so a
        // long value and a long connection list each have room.
        let divider = NSBox()
        divider.boxType = .separator
        let row = NSStackView(views: [detail.view, divider, connectionsView])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .top
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        detailArea.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: detailArea.topAnchor),
            row.leadingAnchor.constraint(equalTo: detailArea.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: detailArea.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: detailArea.bottomAnchor),
            detail.view.heightAnchor.constraint(equalTo: row.heightAnchor),
            divider.heightAnchor.constraint(equalTo: row.heightAnchor),
            connectionsView.heightAnchor.constraint(equalTo: row.heightAnchor),
            connectionsView.widthAnchor.constraint(equalToConstant: 300),
            detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        refreshDetailState()
        connectionsView.show(choices: choicesProvider(variable), linked: variable.connectionIds)
    }

    private func closeDetail() {
        guard let detail = detailVC else { return }
        detail.view.superview?.removeFromSuperview()
        detail.view.removeFromSuperview()
        connectionsView.removeFromSuperview()
        detail.removeFromParent()
        detailVC = nil
        selectedId = nil
        listView.selectedId = nil
    }

    private func showEmptyState() {
        closeDetail()
        emptyState.isHidden = false
    }

    // MARK: - Mutations (the panel's rules)

    func addVariable() {
        let variable = QueryVariable(name: "", value: "", type: .literal)
        variables.append(variable)
        onChange?(variables)
        refreshList()
        select(variable.id)
        detailVC?.focusNameField()
    }

    /// Open the variable called `name`; make it when there is none, with the
    /// caret in its value. A click on a `{{name}}` token, the `{{` list's new
    /// variable row and a run's "undefined" error land here.
    func openVariable(named name: String) {
        if let existing = variables.last(where: { $0.name == name }) {
            select(existing.id)
            return
        }
        let variable = QueryVariable(name: name, value: "", type: .literal)
        variables.append(variable)
        onChange?(variables)
        refreshList()
        select(variable.id)
        detailVC?.focusValueField()
    }

    func deleteVariable(_ id: UUID) {
        variables.removeAll { $0.id == id }
        onChange?(variables)
        if selectedId == id { showEmptyState() }
        refreshList()
    }

    private func variableEdited(_ updated: QueryVariable) {
        guard let index = variables.firstIndex(where: { $0.id == updated.id }) else { return }
        // The detail pane holds its own copy and never edits the links: keep
        // the ones the Connections section set since it opened.
        var merged = updated
        merged.connectionIds = variables[index].connectionIds
        variables[index] = merged
        onChange?(variables)
        refreshDetailState()
        refreshList()
    }

    private func connectionsChanged(_ ids: [String]) {
        guard let id = selectedId, let index = variables.firstIndex(where: { $0.id == id }) else { return }
        variables[index].connectionIds = ids
        onChange?(variables)
        refreshList()
    }

    private func pruneIfAbandoned(_ variable: QueryVariable) {
        guard variable.name.isEmpty, variable.value.isEmpty,
              variables.contains(where: { $0.id == variable.id }) else { return }
        variables.removeAll { $0.id == variable.id }
        onChange?(variables)
        refreshList()
    }

    private func refreshDetailState() {
        guard let detail = detailVC else { return }
        detail.otherNames = Set(variables.filter { $0.id != detail.variable.id }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        detail.setState(VariableSubstitutor.rowStates(in: variables, referenced: [])[detail.variable.id])
    }

    // MARK: - Filter

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter(sender.stringValue)
    }

    func applyFilter(_ text: String) {
        filterText = text.lowercased()
        refreshList()
    }

    private func refreshList() {
        let needle = filterText
        listView.setVariables(variables, referenced: [], visible: { variable in
            needle.isEmpty || variable.name.lowercased().contains(needle) || variable.value.lowercased().contains(needle)
        })
        listView.selectedId = selectedId
    }
}
