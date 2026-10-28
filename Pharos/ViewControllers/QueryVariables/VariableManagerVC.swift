import AppKit

/// The Variable Manager window's content: the app-wide query variables in the
/// manager shell (`ManagerSplitViewController`) — one sidebar row per
/// variable, and the selected variable's form on the right
/// (`VariableDetailVC`), whose Connections box holds `connectionsView`.
///
/// Host-agnostic: the list comes in through `setVariables`, every edit goes
/// out through `onChange`, and the connection choices come from
/// `choicesProvider`. The rules: a name edit commits at a settle point
/// (another row, the window closing), a duplicate name is refused, and a row
/// left empty in name and value is dropped when it is left.
final class VariableManagerVC: NSViewController {

    var onChange: (([QueryVariable]) -> Void)?
    /// The connections a variable can be linked to, with names and tiles.
    var choicesProvider: (QueryVariable) -> [VariableConnectionsView.Choice] = { _ in [] }

    private(set) var variables: [QueryVariable] = []
    private(set) var selectedId: UUID?

    /// The detail's narrowest width: the form's controls and its 20 pt pane
    /// insets fit, and the window's 720 pt minimum leaves the sidebar its 220.
    static let detailMinimum: CGFloat = 460

    let sidebar = ManagerSidebarVC(accessibilityLabel: String(localized: "Variables"))
    let toolbarController = ManagerToolbarController(identifier: "PharosVariableManagerToolbar",
                                                     addLabel: String(localized: "New Variable"))
    private(set) lazy var split: ManagerSplitViewController = {
        let split = ManagerSplitViewController(sidebar: self.sidebar, detail: self.emptyStateVC,
                                               autosaveName: "PharosVariableManagerSplit",
                                               detailMinimum: Self.detailMinimum)
        split.toolbarController = self.toolbarController
        return split
    }()
    /// The detail while no variable is open: "No Variables" with New Variable
    /// while the list is empty, else "No Variable Selected".
    let emptyStateVC = VariableManagerEmptyStateVC()
    let connectionsView = VariableConnectionsView()
    private(set) var detailVC: VariableDetailVC?

    // MARK: - Input

    /// Adopt `vars` (the first load, or another surface's edit). The list
    /// follows at once; the open form is left alone while the user types in
    /// it (`VariableDetailVC.adoptExternalChange`), so a republish from the
    /// store cannot eat an edit in progress (lessons, 2026-09-16). The
    /// selection stays while its variable is there.
    func setVariables(_ vars: [QueryVariable]) {
        guard vars != variables else { return }
        variables = vars
        if let id = selectedId {
            if let incoming = vars.first(where: { $0.id == id }) {
                detailVC?.adoptExternalChange(incoming)
                // Only a real change: "Only these connections" with nothing
                // ticked yet is the view's own state, and a refresh would
                // flip it back to "All connections".
                if connectionsView.tickedIds != incoming.connectionIds {
                    connectionsView.show(choices: choicesProvider(incoming), linked: incoming.connectionIds)
                }
            } else {
                showEmptyState()
            }
        }
        refreshList()
        refreshDetailState()
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

    /// Give `window` the manager toolbar (+ and the filter field), once.
    func installToolbar(on window: NSWindow) {
        _ = view
        split.installToolbarIfNeeded(on: window)
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        view = root
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split.view)
        NSLayoutConstraint.activate([
            // The window's top: the sidebar's glass and the form's scroll view
            // both run under the toolbar.
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        toolbarController.onAdd = { [weak self] in self?.addVariable() }
        emptyStateVC.onAdd = { [weak self] in self?.addVariable() }
        sidebar.onSelect = { [weak self] id in self?.userSelected(id.flatMap(UUID.init(uuidString:))) }
        sidebar.onDelete = { [weak self] ids in
            for id in ids.compactMap(UUID.init(uuidString:)) { self?.deleteVariable(id) }
        }
        sidebar.onDuplicate = { [weak self] id in
            guard let uuid = UUID(uuidString: id) else { return }
            self?.duplicateVariable(uuid)
        }
        connectionsView.onChange = { [weak self] ids in self?.connectionsChanged(ids) }
        refreshList()
    }

    // MARK: - Selection

    /// The user picked a row in the sidebar, or cleared the selection.
    private func userSelected(_ id: UUID?) {
        if let id {
            select(id)
        } else if leaveCurrentDetail() {
            showEmptyState()
        } else {
            sidebar.selectedId = selectedId?.uuidString
        }
    }

    func select(_ id: UUID) {
        guard id != selectedId else {
            sidebar.selectedId = id.uuidString
            return
        }
        // Leaving a row is a settle point; a colliding name refuses to go,
        // and the sidebar's selection goes back to it.
        guard leaveCurrentDetail() else {
            sidebar.selectedId = selectedId?.uuidString
            return
        }
        guard variables.contains(where: { $0.id == id }) else {
            showEmptyState()
            return
        }
        showDetail(for: id)
        refreshList()
    }

    /// Settle the open form and close it. False, and the form stays, while
    /// its name collides.
    private func leaveCurrentDetail() -> Bool {
        guard let detail = detailVC else { return true }
        guard !detail.isNameCollision else {
            detail.focusNameField()
            return false
        }
        detail.settleForDismissal()
        let leaving = detail.variable
        closeDetail()
        pruneIfAbandoned(leaving)
        return true
    }

    private func showDetail(for id: UUID) {
        guard let variable = variables.first(where: { $0.id == id }) else { return }
        let detail = VariableDetailVC(variable: variable, connectionsView: connectionsView)
        detail.onChange = { [weak self] updated in self?.variableEdited(updated) }
        detail.onDelete = { [weak self] in self?.deleteVariable(id) }
        detail.onBack = { [weak self] in self?.settlePendingEdit() }
        detailVC = detail
        selectedId = id
        sidebar.selectedId = id.uuidString
        // Before the form loads: it checks the name against `otherNames`
        // as it builds.
        refreshDetailState()
        connectionsView.show(choices: choicesProvider(variable), linked: variable.connectionIds)
        split.setDetail(detail)
    }

    private func closeDetail() {
        guard detailVC != nil else { return }
        connectionsView.removeFromSuperview()
        detailVC = nil
        selectedId = nil
        sidebar.selectedId = nil
    }

    private func showEmptyState() {
        closeDetail()
        _ = view
        split.setDetail(emptyStateVC)
    }

    // MARK: - Mutations

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

    /// Delete at once (the sidebar's Delete key and menu, the form's
    /// button). The form closes when its variable goes.
    func deleteVariable(_ id: UUID) {
        guard variables.contains(where: { $0.id == id }) else { return }
        variables.removeAll { $0.id == id }
        onChange?(variables)
        if selectedId == id { showEmptyState() }
        refreshList()
        refreshDetailState()
    }

    /// A copy just below the original, named `<name>_copy` (then `_copy2`,
    /// `_copy3` … while that is taken), and open it.
    func duplicateVariable(_ id: UUID) {
        if id == selectedId { detailVC?.settleForDismissal() }
        guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
        let source = variables[index]
        let taken = Set(variables.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        let copy = QueryVariable(name: Self.copyName(for: source.name, taken: taken), value: source.value,
                                 type: source.type, connectionIds: source.connectionIds)
        variables.insert(copy, at: index + 1)
        onChange?(variables)
        refreshList()
        refreshDetailState()
        select(copy.id)
    }

    static func copyName(for name: String, taken: Set<String>) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines) + "_copy"
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)\(number)") { number += 1 }
        return "\(base)\(number)"
    }

    private func variableEdited(_ updated: QueryVariable) {
        guard let index = variables.firstIndex(where: { $0.id == updated.id }) else { return }
        // The form holds its own copy and never edits the links: keep the
        // ones the Connections box set since it opened.
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

    // MARK: - States

    /// Every name counts as referenced: the Manager shows each variable's
    /// problem, not only those a query on screen uses.
    private var rowStates: [UUID: VariableSubstitutor.RowState] {
        VariableSubstitutor.rowStates(in: variables, referenced: Set(variables.map(\.name)))
    }

    private func refreshDetailState() {
        guard let detail = detailVC else { return }
        detail.otherNames = Set(variables.filter { $0.id != detail.variable.id }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        detail.setState(rowStates[detail.variable.id])
    }

    // MARK: - Sidebar

    /// The filter the toolbar's field drives.
    func applyFilter(_ text: String) {
        sidebar.filterText = text
    }

    private func refreshList() {
        let states = rowStates
        sidebar.setItems(variables.map { Self.sidebarItem(for: $0, state: states[$0.id]) })
        sidebar.selectedId = selectedId?.uuidString
        emptyStateVC.hasVariables = !variables.isEmpty
    }

    /// `{{name}}` monospaced ("Untitled" for a blank name), "<Type> ·
    /// <value>" with " · N connections" when linked, and a warning that
    /// carries the problem's message.
    static func sidebarItem(for variable: QueryVariable, state: VariableSubstitutor.RowState?) -> ManagerSidebarItem {
        let name = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? String(localized: "Untitled") : "{{" + DisplayEscape.escaped(name) + "}}"
        var subtitle = variable.type.family.displayName + " · " + preview(of: variable)
        if !variable.isGlobal {
            subtitle += " · " + CountedNounText.phrase(variable.connectionIds.count, "connection")
        }
        var trailing: [ManagerSidebarItem.Accessory] = []
        if let problem = state?.problem {
            trailing.append(.warning(tooltip: VariableDetailVC.problemSentence(problem)))
        }
        return ManagerSidebarItem(id: variable.id.uuidString, title: title, titleIsMonospaced: !name.isEmpty,
                                  subtitle: subtitle, trailing: trailing)
    }

    /// The value as one short phrase: "Today", "Now", "True", "12 items",
    /// or the first line of the value.
    static func preview(of variable: QueryVariable) -> String {
        let value = variable.value
        switch variable.type {
        case .bool:
            if let index = VariableDetailVC.boolSegmentIndex(for: value) { return VariableDetailVC.boolSegmentLabels[index] }
        case .date:
            if VariableValueRules.isRelative(value, as: .date) { return String(localized: "Today") }
        case .timestamp, .timestamptz:
            if VariableValueRules.isRelative(value, as: variable.type) { return String(localized: "Now") }
        case .textList, .numberList:
            return CountedNounText.phrase(VariableValueRules.listItems(in: value).count, "item")
        default:
            break
        }
        if value.isEmpty { return String(localized: "No value") }
        let snippet = VariableValuePreview.snippet(for: value)
        // Only blanks: say how many, as the caption does.
        return snippet.isEmpty ? VariableValuePreview.caption(for: value) : DisplayEscape.escaped(snippet)
    }
}

/// The detail while no variable is open. With none at all it says so and
/// offers New Variable, as the Tag Manager's "No Tags" offers New Tag; with
/// some, it asks for a pick.
final class VariableManagerEmptyStateVC: NSViewController {
    /// The New Variable button, shown while there are no variables.
    var onAdd: (() -> Void)?
    /// Whether the list holds any variable. The owner keeps it current.
    var hasVariables = false {
        didSet { if hasVariables != oldValue, isViewLoaded { applyState() } }
    }
    let emptyState = EmptyStateView()

    override func loadView() {
        let root = NSView()
        let empty = emptyState
        applyState()
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            // Its own safe area: not a scroll view, so it does not inset
            // itself under the toolbar (lessons, 2026-09-16).
            empty.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func applyState() {
        if hasVariables {
            emptyState.show(symbol: "curlybraces", title: String(localized: "No Variable Selected"),
                            message: String(localized: "Select a variable, or click + to add one."))
        } else {
            emptyState.show(
                symbol: "curlybraces",
                title: String(localized: "No Variables", comment: "Variable Manager: the empty state's title."),
                message: String(localized: "A variable is a named value that a query uses as {{name}} — text, a number, a date, a list.",
                                comment: "Variable Manager: the empty state's message."),
                actionTitle: String(localized: "New Variable"),
                action: { [weak self] in self?.onAdd?() })
        }
    }
}
