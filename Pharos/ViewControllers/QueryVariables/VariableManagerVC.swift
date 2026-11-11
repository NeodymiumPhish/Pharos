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
///
/// Several rows can be selected (⌘-click, ⇧-click, ⌘A). The form then gives
/// way to "N Variables Selected", and the selection's context menu sets the
/// AI apps choice of all of them or deletes them. The toolbar's Sort and
/// Filter menu orders the sidebar and narrows it by type and by AI apps
/// choice (`VariableListOptions`); the filter field narrows it by text.
final class VariableManagerVC: NSViewController {

    var onChange: (([QueryVariable]) -> Void)?
    /// The connections a variable can be linked to, with names and tiles.
    var choicesProvider: (QueryVariable) -> [VariableConnectionsView.Choice] = { _ in [] }

    private(set) var variables: [QueryVariable] = []
    private(set) var selectedId: UUID?
    /// The rows selected together, while there are two or more. No form is
    /// open then (`selectedId` is nil).
    private(set) var multiSelectedIds: [UUID] = []

    /// The sidebar's order and its type and AI apps filters. The order is
    /// remembered; the filters are not, so the window never opens on a list
    /// that is silently short.
    private(set) var listOptions = VariableListOptions.restored() {
        didSet {
            guard listOptions != oldValue else { return }
            listOptions.remember()
            rebuildOptionsMenu()
            refreshList()
        }
    }
    let optionsMenu = NSMenu()

    /// Asks before several variables are deleted at once, then calls
    /// `proceed`. One variable is deleted at once, as before. The harness
    /// replaces it.
    var confirmBulkDelete: (_ count: Int, _ window: NSWindow?, _ proceed: @escaping () -> Void) -> Void = { count, window, proceed in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete \(count) variables?",
                                   comment: "Variable Manager: confirming a bulk delete. The count is 2 or more.")
        alert.informativeText = String(localized: "Cards that use them cannot run until the variables are defined again. You can’t undo this.")
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { proceed() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

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
        self.toolbarController.optionsMenu = self.optionsMenu
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
        dropMissingFromMultiSelection()
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
        sidebar.allowsMultipleSelection = true
        sidebar.onSelect = { [weak self] id in self?.userSelected(id.flatMap(UUID.init(uuidString:))) }
        sidebar.onSelectMany = { [weak self] ids in self?.userSelectedMany(ids.compactMap(UUID.init(uuidString:))) }
        sidebar.onDelete = { [weak self] ids in self?.deleteVariables(ids.compactMap(UUID.init(uuidString:))) }
        sidebar.deleteTitle = { count in
            count == 1 ? String(localized: "Delete")
                : String(localized: "Delete \(count) Variables", comment: "Variable Manager: the context menu of a selection of several.")
        }
        sidebar.contextMenuItems = { [weak self] ids in
            self?.aiAppsMenuItems(for: ids.compactMap(UUID.init(uuidString:))) ?? []
        }
        sidebar.onDuplicate = { [weak self] id in
            guard let uuid = UUID(uuidString: id) else { return }
            self?.duplicateVariable(uuid)
        }
        connectionsView.onChange = { [weak self] ids in self?.connectionsChanged(ids) }
        rebuildOptionsMenu()
        refreshList()
    }

    // MARK: - Selection

    /// The user picked a row in the sidebar, or cleared the selection.
    private func userSelected(_ id: UUID?) {
        setMultiSelection([])
        if let id {
            select(id)
        } else if leaveCurrentDetail() {
            showEmptyState()
        } else {
            sidebar.selectedId = selectedId?.uuidString
        }
    }

    /// The user selected several rows: the open form settles and closes (a
    /// colliding name refuses, and the selection goes back to its row), and
    /// the detail says how many are selected.
    private func userSelectedMany(_ ids: [UUID]) {
        guard leaveCurrentDetail() else {
            sidebar.selectedId = selectedId?.uuidString
            return
        }
        showEmptyState()
        // Leaving a row can drop it (an abandoned empty one).
        setMultiSelection(ids.filter { id in variables.contains { $0.id == id } })
        refreshList()
    }

    private func setMultiSelection(_ ids: [UUID]) {
        multiSelectedIds = ids.count > 1 ? ids : []
        emptyStateVC.selectionCount = multiSelectedIds.count
    }

    private func dropMissingFromMultiSelection() {
        guard !multiSelectedIds.isEmpty else { return }
        setMultiSelection(multiSelectedIds.filter { id in variables.contains { $0.id == id } })
    }

    func select(_ id: UUID) {
        setMultiSelection([])
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
        dropMissingFromMultiSelection()
        onChange?(variables)
        if selectedId == id { showEmptyState() }
        refreshList()
        refreshDetailState()
    }

    /// Delete from the sidebar (the Delete key, Edit ▸ Delete, the context
    /// menu): one variable at once, several after `confirmBulkDelete`.
    func deleteVariables(_ ids: [UUID]) {
        let present = ids.filter { id in variables.contains { $0.id == id } }
        guard present.count > 1 else {
            if let id = present.first { deleteVariable(id) }
            return
        }
        confirmBulkDelete(present.count, viewIfLoaded?.window) { [weak self] in
            self?.removeVariables(Set(present))
        }
    }

    private func removeVariables(_ ids: Set<UUID>) {
        guard variables.contains(where: { ids.contains($0.id) }) else { return }
        if let selectedId, ids.contains(selectedId) { showEmptyState() }
        variables.removeAll { ids.contains($0.id) }
        dropMissingFromMultiSelection()
        onChange?(variables)
        refreshList()
        refreshDetailState()
    }

    /// Give every one of `ids` the AI apps choice `access` (the context
    /// menu's AI Apps submenu, for one row or a selection). The open form
    /// follows.
    func setAIAccess(_ access: VariableAIAccess, for ids: [UUID]) {
        let targets = Set(ids)
        var changed = false
        for index in variables.indices where targets.contains(variables[index].id)
            && variables[index].mcpAccess != access {
            variables[index].mcpAccess = access
            changed = true
        }
        guard changed else { return }
        if let detail = detailVC, let open = variables.first(where: { $0.id == detail.variable.id }) {
            detail.adoptExternalChange(open)
        }
        onChange?(variables)
        refreshList()
    }

    /// The context menu's AI Apps submenu for `ids`: the three choices, with
    /// a tick on the one they all have and a dash on those only some have.
    func aiAppsMenuItems(for ids: [UUID]) -> [NSMenuItem] {
        let targets = variables.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return [] }
        let parent = NSMenuItem(title: String(localized: "AI Apps"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for access in VariableAIAccess.allCases {
            let item = NSMenuItem(title: access.displayLabel, action: #selector(aiAccessFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AIAccessMenuChoice(access: access, ids: targets.map(\.id))
            let having = targets.filter { $0.mcpAccess == access }.count
            item.state = having == targets.count ? .on : (having > 0 ? .mixed : .off)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return [parent]
    }

    @objc private func aiAccessFromMenu(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AIAccessMenuChoice else { return }
        setAIAccess(choice.access, for: choice.ids)
    }

    /// A copy just below the original, named `<name>_copy` (then `_copy2`,
    /// `_copy3` … while that is taken), and open it.
    func duplicateVariable(_ id: UUID) {
        if id == selectedId { detailVC?.settleForDismissal() }
        guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
        let source = variables[index]
        let taken = Set(variables.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        let copy = QueryVariable(name: Self.copyName(for: source.name, taken: taken), value: source.value,
                                 type: source.type, connectionIds: source.connectionIds,
                                 mcpAccess: source.mcpAccess)
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
        dropMissingFromMultiSelection()
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
        // "No Matches" only when the menu's filters hid everything there is.
        sidebar.ownerIsFiltering = listOptions.isFiltering && !variables.isEmpty
        sidebar.setItems(listOptions.apply(to: variables).map { Self.sidebarItem(for: $0, state: states[$0.id]) })
        if multiSelectedIds.isEmpty {
            sidebar.selectedId = selectedId?.uuidString
        } else {
            sidebar.selectedIds = multiSelectedIds.map(\.uuidString)
        }
        emptyStateVC.hasVariables = !variables.isEmpty
        toolbarController.optionsAreActive = listOptions.isFiltering
    }

    // MARK: - Sort and Filter

    /// Order the sidebar by `sort`; choosing the order it already has turns
    /// it round, as a table's column header does.
    func setSort(_ sort: VariableListOptions.Sort) {
        if listOptions.sort == sort {
            listOptions.ascending.toggle()
        } else {
            listOptions.sort = sort
            listOptions.ascending = true
        }
    }

    func setSortAscending(_ ascending: Bool) { listOptions.ascending = ascending }
    /// Show only variables of this type; nil shows every type.
    func setTypeFilter(_ family: VariableTypeFamily?) { listOptions.typeFilter = family }
    /// Show only variables with this AI apps choice; nil shows every choice.
    func setAIFilter(_ access: VariableAIAccess?) { listOptions.aiFilter = access }

    func clearFilters() {
        listOptions.typeFilter = nil
        listOptions.aiFilter = nil
    }

    /// The toolbar's Sort and Filter menu, rebuilt whenever a choice changes
    /// so its ticks are right when it opens.
    private func rebuildOptionsMenu() {
        let menu = optionsMenu
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool, object: Any? = nil, to target: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            item.state = on ? .on : .off
            target.addItem(item)
        }

        menu.addItem(.sectionHeader(title: String(localized: "Sort By")))
        for sort in VariableListOptions.Sort.allCases {
            add(sort.displayName, #selector(sortFromMenu(_:)), on: listOptions.sort == sort, object: sort.rawValue, to: menu)
        }
        menu.addItem(.separator())
        add(String(localized: "Ascending"), #selector(ascendingFromMenu(_:)), on: listOptions.ascending, to: menu)
        add(String(localized: "Descending"), #selector(descendingFromMenu(_:)), on: !listOptions.ascending, to: menu)

        menu.addItem(.sectionHeader(title: String(localized: "Filter")))
        let types = NSMenuItem(title: String(localized: "Type"), action: nil, keyEquivalent: "")
        let typeMenu = NSMenu()
        add(String(localized: "All Types"), #selector(typeFilterFromMenu(_:)), on: listOptions.typeFilter == nil, to: typeMenu)
        typeMenu.addItem(.separator())
        for family in VariableTypeFamily.allCases {
            add(family.displayName, #selector(typeFilterFromMenu(_:)), on: listOptions.typeFilter == family,
                object: family.rawValue, to: typeMenu)
        }
        types.submenu = typeMenu
        types.state = listOptions.typeFilter == nil ? .off : .on
        menu.addItem(types)

        let apps = NSMenuItem(title: String(localized: "AI Apps"), action: nil, keyEquivalent: "")
        let appsMenu = NSMenu()
        add(String(localized: "Any Choice", comment: "Variable Manager: the AI apps filter that hides nothing."),
            #selector(aiFilterFromMenu(_:)), on: listOptions.aiFilter == nil, to: appsMenu)
        appsMenu.addItem(.separator())
        for access in VariableAIAccess.allCases {
            add(access.displayLabel, #selector(aiFilterFromMenu(_:)), on: listOptions.aiFilter == access,
                object: access.rawValue, to: appsMenu)
        }
        apps.submenu = appsMenu
        apps.state = listOptions.aiFilter == nil ? .off : .on
        menu.addItem(apps)

        menu.addItem(.separator())
        let clear = NSMenuItem(title: String(localized: "Clear Filters"), action: #selector(clearFiltersFromMenu(_:)),
                               keyEquivalent: "")
        clear.target = listOptions.isFiltering ? self : nil
        clear.isEnabled = listOptions.isFiltering
        menu.addItem(clear)
        menu.autoenablesItems = false
    }

    @objc private func sortFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sort = VariableListOptions.Sort(rawValue: raw) else { return }
        setSort(sort)
    }

    @objc private func ascendingFromMenu(_ sender: NSMenuItem) { setSortAscending(true) }
    @objc private func descendingFromMenu(_ sender: NSMenuItem) { setSortAscending(false) }

    @objc private func typeFilterFromMenu(_ sender: NSMenuItem) {
        setTypeFilter((sender.representedObject as? String).flatMap(VariableTypeFamily.init(rawValue:)))
    }

    @objc private func aiFilterFromMenu(_ sender: NSMenuItem) {
        setAIFilter((sender.representedObject as? String).flatMap(VariableAIAccess.init(rawValue:)))
    }

    @objc private func clearFiltersFromMenu(_ sender: NSMenuItem) { clearFilters() }

    /// `{{name}}` monospaced ("Untitled" for a blank name), "<Type> ·
    /// <value>" with " · N connections" when linked, a mark while AI apps
    /// can use it, and a warning that carries the problem's message.
    static func sidebarItem(for variable: QueryVariable, state: VariableSubstitutor.RowState?) -> ManagerSidebarItem {
        let name = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? String(localized: "Untitled") : "{{" + DisplayEscape.escaped(name) + "}}"
        var subtitle = variable.type.family.displayName + " · " + preview(of: variable)
        if !variable.isGlobal {
            subtitle += " · " + CountedNounText.phrase(variable.connectionIds.count, "connection")
        }
        var trailing: [ManagerSidebarItem.Accessory] = []
        if variable.mcpAccess != .off {
            // Sparkles is the app's mark for AI apps (Settings ▸ Security &
            // Privacy); a Mac for those whose model runs on this one.
            trailing.append(.symbol(name: variable.mcpAccess == .local ? "laptopcomputer" : "sparkles",
                                    label: String(localized: "AI apps: \(variable.mcpAccess.displayLabel)",
                                                  comment: "Variable Manager: a sidebar row's mark; the argument is the AI apps choice.")))
        }
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
    /// How many rows are selected together: two or more, or 0 for none.
    var selectionCount = 0 {
        didSet { if selectionCount != oldValue, isViewLoaded { applyState() } }
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
        if selectionCount > 1 {
            emptyState.show(
                symbol: "curlybraces",
                title: String(localized: "\(selectionCount) Variables Selected",
                              comment: "Variable Manager: the detail while several rows are selected. The count is 2 or more."),
                message: String(localized: "Control-click the selection to choose its AI apps, or to delete it."))
        } else if hasVariables {
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

/// What an item of the context menu's AI Apps submenu sets, and on which
/// variables.
private final class AIAccessMenuChoice: NSObject {
    let access: VariableAIAccess
    let ids: [UUID]
    init(access: VariableAIAccess, ids: [UUID]) {
        self.access = access
        self.ids = ids
    }
}

extension VariableListOptions {
    static let sortDefaultsKey = "PharosVariableManagerSort"
    static let descendingDefaultsKey = "PharosVariableManagerSortDescending"

    /// The remembered order, with no filter.
    static func restored(from defaults: UserDefaults = .standard) -> VariableListOptions {
        var options = VariableListOptions()
        if let raw = defaults.string(forKey: sortDefaultsKey), let sort = Sort(rawValue: raw) { options.sort = sort }
        options.ascending = !defaults.bool(forKey: descendingDefaultsKey)
        return options
    }

    func remember(in defaults: UserDefaults = .standard) {
        defaults.set(sort.rawValue, forKey: Self.sortDefaultsKey)
        defaults.set(!ascending, forKey: Self.descendingDefaultsKey)
    }
}
