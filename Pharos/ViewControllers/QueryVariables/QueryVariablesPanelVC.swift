import AppKit

/// The Variables navigator's content: the app-wide query variables as two
/// levels — a read-only list, and a detail level for one variable. This
/// controller owns the variable array and the level swap; each level owns its
/// own header and rendering.
///
/// Host-agnostic: `[QueryVariable]` and the referenced-name set come in through
/// `setVariables`, edits go out through `onChange`, and nothing here knows
/// about the store or the sidebar. The root view paints NOTHING — it sits on
/// the sidebar's own material, like the other three sidebar lists — and there
/// is no leading hairline, because the split view's divider already draws
/// the pane's edge.
final class QueryVariablesPanelVC: NSViewController {

    /// Called whenever the variable set changes (add / delete / edit).
    var onChange: (([QueryVariable]) -> Void)?

    private(set) var variables: [QueryVariable] = []

    /// Whether the list level shows its own title / count / "+" header.
    /// The sidebar turns it off: the navigator group names the list, and the
    /// filter bar's "+" adds to it. Forwarded straight to the list view, which
    /// exists from `init`, so this can be set before `loadView` runs.
    var showsListHeader: Bool = true {
        didSet { listView.showsHeader = showsListHeader }
    }

    /// The sidebar's filter text, lower-cased; empty means every row shows.
    /// Applied in `refreshList()` as a case-insensitive substring match on
    /// the name and the value. Row STATES are still computed over the whole
    /// array — see `VariableListView.setVariables(_:referenced:visible:)`.
    private var filterText = ""

    /// Names the current SQL references. Combined with each variable's value to
    /// decide the red failure state — an unreferenced variable is never flagged.
    /// (The duplicate-name signal does not depend on this: a shadowed row is
    /// inert whether or not anything references its name.)
    private var referenced: Set<String> = []

    private let contentArea = NSView()
    private let listView = VariableListView()
    private var detailVC: VariableDetailVC?
    private var isAnimating = false

    /// Whether level swaps animate. Consults the system's reduce-motion
    /// setting fresh on every read — not cached at `init` — so toggling
    /// System Settings > Accessibility > Reduce Motion while the app is
    /// running takes effect on the next drill-in/back, rather than needing a
    /// restart. `animatesLevelTransitionsOverride`, once set, wins
    /// unconditionally: a headless test harness has no way to toggle the
    /// real system setting, so this is the explicit seam tests use instead —
    /// forcing the instant (non-animated) path lets most assertions read
    /// final frames deterministically instead of racing a 0.18s animation,
    /// while `testDoubleClickOnRowDoesNotDrillInTwice` forces the opposite
    /// (leaves it animated) to reach the one bug that only exists in that path.
    var animatesLevelTransitions: Bool {
        get { animatesLevelTransitionsOverride ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        set { animatesLevelTransitionsOverride = newValue }
    }
    private var animatesLevelTransitionsOverride: Bool?

    // MARK: - Input

    /// Replace the displayed variables and the referenced-name set. Returns
    /// to the list level, since the detail level belonged to whatever was
    /// showing before.
    ///
    /// The one caller today is the sidebar, on a `QueryVariableStore.didChange`
    /// it did not originate (an edit in ANOTHER window). `variables` is
    /// assigned FIRST and only then is the detail level dismissed, and that
    /// order is load-bearing: `dismissDetail` settles the detail level's name
    /// field as a safety net, and `variableEdited` looks the edited id up in
    /// `variables` — so a rename that was pending here lands on the incoming
    /// list, merged with the other window's change, rather than on the stale
    /// one. (If the other window deleted that very variable, the lookup fails
    /// and the rename is dropped, which is the right answer.) `pruneIfAbandoned`
    /// reads the same array with the same result.
    ///
    /// `settlePendingEdit()` exists for the caller that wants to commit a
    /// pending rename WITHOUT replacing the list — the sidebar, when the user
    /// switches to another navigator while the detail level is showing.
    func setVariables(_ vars: [QueryVariable], referenced: Set<String>) {
        variables = vars
        self.referenced = referenced
        dismissDetail(animated: false)
        refreshList()
    }

    /// Settles (commits if valid, drops if colliding) whatever the detail
    /// level's name field currently shows, and discards the variable
    /// outright if nothing valid was ever entered for it (see
    /// `pruneIfAbandoned`) — without dismissing anything else: no level
    /// swap, no list rebuild. A no-op if the detail level isn't showing.
    ///
    /// The sidebar calls this when the user leaves the Variables navigator
    /// with the detail level showing: the level stays open behind the other
    /// list, but the rename the user typed must not sit uncommitted in a
    /// hidden field — a run in the meantime resolves against the store, and
    /// the store must already hold it.
    ///
    /// History: in the per-tab panel this had to run BEFORE `setVariables`,
    /// because a settle from inside the swap would have looked the edited id
    /// up in the incoming TAB's array and either lost the rename or landed it
    /// on the wrong tab. With one app-wide list there is no wrong list, and
    /// `setVariables` relies on the inside-the-swap settle to merge instead.
    func settlePendingEdit() {
        guard let detail = detailVC else { return }
        detail.settleForDismissal()
        pruneIfAbandoned(detail.variable)
    }

    /// Discards `variable` if it is empty in both (trimmed) name and value —
    /// an abandoned `+` row, or a name that only ever collided (so never
    /// committed, per `commitNameIfValid`'s collision guard) and was never
    /// given a value either. Shared by `settlePendingEdit` (a navigator
    /// switch) and `dismissDetail` (back/delete, and the list replacement in
    /// `setVariables`).
    /// A variable with a non-empty value is always kept, even with an empty
    /// name — the user typed something, and discarding it silently would be
    /// the same class of mistake the mangled-prefix bug was.
    private func pruneIfAbandoned(_ variable: QueryVariable) {
        guard variable.name.isEmpty, variable.value.isEmpty,
              variables.contains(where: { $0.id == variable.id }) else { return }
        variables.removeAll { $0.id == variable.id }
        onChange?(variables)
    }

    /// Narrow the list to rows whose name or value contains `text`
    /// (case-insensitive). The detail level, if showing, is left alone: a
    /// filter is typed in the sidebar's field, and swapping levels under the
    /// user would be a surprise. The list is rebuilt behind it and is what
    /// the user sees on the way back.
    func applyFilter(_ text: String) {
        filterText = text.lowercased()
        refreshList()
    }

    /// Show every row again.
    func clearFilter() {
        guard !filterText.isEmpty else { return }
        filterText = ""
        refreshList()
    }

    private func isVisible(_ variable: QueryVariable) -> Bool {
        filterText.isEmpty
            || variable.name.lowercased().contains(filterText)
            || variable.value.lowercased().contains(filterText)
    }

    /// Update only which names the SQL references — called from the debounced
    /// editor-text scan, so it re-renders row state in place and must not rebuild
    /// anything the user is working in.
    func setReferencedNames(_ names: Set<String>) {
        guard names != referenced else { return }
        referenced = names
        listView.updateStates(for: variables, referenced: referenced)
        refreshDetailState()
    }

    /// Push the detail level's state, resolved against the whole list so that
    /// both of its signals — the red failure and the duplicate-name note — agree
    /// with what the list says about the same row. Also refreshes the
    /// comparison set the detail level checks a typed name against, since the
    /// detail VC cannot see its own siblings and the list can change
    /// underneath it (add / delete / another edit) while it is showing.
    private func refreshDetailState() {
        guard let detail = detailVC else { return }
        detail.otherNames = otherNames(excluding: detail.variable.id)
        let states = VariableSubstitutor.rowStates(in: variables, referenced: referenced)
        detail.setState(states[detail.variable.id])
    }

    /// Trimmed, non-empty names of every variable except `id` — the set a
    /// typed name in the detail level is checked against. Names that trim to
    /// empty are excluded here (not left to the detail level to filter out):
    /// an empty name can never collide with anything, including another
    /// empty name, since two freshly added rows are not duplicates of each
    /// other.
    private func otherNames(excluding id: UUID) -> Set<String> {
        Set(
            variables
                .filter { $0.id != id }
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - View

    override func loadView() {
        // A plain, non-painting root: the sidebar's split view item supplies
        // the material, and an opaque plate here would sit on top of it.
        let container = NSView()
        self.view = container

        contentArea.wantsLayer = true
        // The level-slide animation parallaxes the outgoing view to
        // `x = -bounds.width * 0.35` (see `push`/`pop` below). AppKit does not
        // clip subviews to their superview's bounds by default, so without
        // this the part that slides past the leading edge keeps drawing —
        // over the split view divider and into the neighbouring pane — until
        // the animation completes. `contentArea` is already layer-backed, so
        // `masksToBounds` is the minimal fix.
        contentArea.layer?.masksToBounds = true
        contentArea.translatesAutoresizingMaskIntoConstraints = false

        listView.onAdd = { [weak self] in self?.addVariable() }
        listView.onSelect = { [weak self] id in self?.drillIn(to: id) }
        listView.onDelete = { [weak self] id in self?.deleteVariable(id) }
        contentArea.addSubview(listView)

        container.addSubview(contentArea)

        NSLayoutConstraint.activate([
            // The SAFE-AREA top, not the view's top. In the sidebar this view
            // runs up under the toolbar glass, and only an NSScrollView insets
            // itself for that automatically: the detail level's header row
            // (Back, name, type, Delete) is frame-laid-out and was measured
            // live sitting 5pt below the window's top edge, hidden under the
            // toolbar, while its value editor's scroll view had inset itself
            // 52pt. Pinning the whole content area below the safe area gives
            // both levels one consistent top. The cost is that the list does
            // not scroll under the glass the way the other three sidebar lists
            // do; a header that hides under it is the worse trade.
            contentArea.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        refreshList()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Levels are frame-laid-out so they can slide; skip while a slide is in
        // flight or it would snap them to their final frames mid-animation.
        guard !isAnimating else { return }
        let bounds = contentArea.bounds
        listView.frame = bounds
        detailVC?.view.frame = bounds
        listView.isHidden = detailVC != nil
    }

    // MARK: - Level swap

    /// Re-entrancy guard. `VariableRowView.mouseUp` fires `onClick` on every
    /// `mouseUp`, including the second one in a double-click — it does not
    /// check `clickCount` — and `push` only sets `listView.isHidden = true`
    /// inside its animation completion handler, up to `slideDuration` (180ms)
    /// later; until then the list is still visible and hit-testable. Without
    /// this guard, the second click's `drillIn` call would add a SECOND
    /// `VariableDetailVC` as a child and a second view into `contentArea`
    /// while the first is still there, overwriting `detailVC` to point at
    /// the second and orphaning the first: `pop` only ever removes the one
    /// view it is handed, so the first, orphaned child never gets
    /// `removeFromParent()`'d or has its view removed. It sits on top of the
    /// list (added to `contentArea` after `listView`, so it draws above it)
    /// and its Back button still hit-tests — but the closure it fires is
    /// `{ self?.dismissDetail(...) }`, which acts on whichever child
    /// `detailVC` *currently* references (the second one, not itself), so
    /// clicking it dismisses the wrong child and leaves `detailVC` nil with
    /// the orphan still on screen; every interaction after that (another
    /// click on the orphan's own Back, or a tab switch) hits
    /// `dismissDetail`'s `detailVC == nil` early return and does nothing.
    ///
    /// Also gates on `!isAnimating`, not just `detailVC == nil`, to close a
    /// second, narrower window: `dismissDetail` sets `detailVC = nil`
    /// *before* `pop`'s animation runs, so for the ~180ms the list is
    /// sliding back into view after Back, `detailVC` is already nil while a
    /// transition is still structurally in flight. `viewDidLayout` already
    /// treats `isAnimating` as "no structural frame changes right now" for
    /// exactly this reason; a `drillIn` landing mid-pop would add a child and
    /// push a new animation on top of one whose completion handler hasn't
    /// run yet, racing which one's `isAnimating = false` wins.
    private func drillIn(to id: UUID) {
        guard detailVC == nil, !isAnimating else { return }
        guard let variable = variables.first(where: { $0.id == id }) else { return }

        let detail = VariableDetailVC(variable: variable)
        detail.onChange = { [weak self] updated in self?.variableEdited(updated) }
        detail.onDelete = { [weak self] in self?.deleteVariable(id) }
        detail.onBack = { [weak self] in self?.dismissDetail(animated: true) }
        addChild(detail)
        detailVC = detail
        refreshDetailState()

        push(detail.view)
    }

    /// Return to the list level. Discards a variable that is empty in both
    /// (trimmed) name and value — an abandoned `+` row, or a name that only
    /// ever collided and so never committed — on EVERY dismissal path now,
    /// not only back: a colliding draft never commits regardless of how the
    /// detail level closes, so a variable left with an empty name this way
    /// is exactly as abandoned whether the user pressed Back or the list was
    /// replaced under it. (History: this used to only prune when `onBack`
    /// passed `pruningEmpty: true`, and the tab-switch path passed `false` —
    /// leaving a variable that was typed toward a colliding name, then
    /// abandoned by switching tabs, sitting in the list forever as a
    /// subdued, valueless row. Made uniform instead of threading a flag
    /// through every caller.)
    ///
    /// Every path here — `onBack` (which already settled via `attemptBack`
    /// before calling this), and every other path that tears the detail
    /// level down without going through it at all (`setVariables` from
    /// another window's edit) — must settle the name field, and prune if
    /// abandoned, before reading `detail.variable` below.
    /// `settleForDismissal()`/`pruneIfAbandoned` are no-ops if
    /// `settlePendingEdit()` already ran for this same variable.
    private func dismissDetail(animated: Bool) {
        guard let detail = detailVC else {
            listView.isHidden = false
            listView.frame = contentArea.bounds
            return
        }

        detail.settleForDismissal()
        pruneIfAbandoned(detail.variable)

        detail.removeFromParent()
        detailVC = nil
        refreshList()
        pop(detail.view, animated: animated)
    }

    private static let slideDuration: TimeInterval = 0.18

    private func push(_ incoming: NSView) {
        let bounds = contentArea.bounds
        contentArea.addSubview(incoming)
        listView.isHidden = false

        guard animatesLevelTransitions, bounds.width > 0 else {
            incoming.frame = bounds
            listView.isHidden = true
            return
        }

        incoming.frame = NSRect(x: bounds.width, y: 0, width: bounds.width, height: bounds.height)
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.animator().frame = bounds
            self.listView.animator().frame = NSRect(
                x: -bounds.width * 0.35, y: 0, width: bounds.width, height: bounds.height)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            self.listView.isHidden = true
            self.view.needsLayout = true
        })
    }

    private func pop(_ outgoing: NSView, animated: Bool) {
        let bounds = contentArea.bounds
        listView.isHidden = false

        guard animated, animatesLevelTransitions, bounds.width > 0 else {
            outgoing.removeFromSuperview()
            listView.frame = bounds
            return
        }

        listView.frame = NSRect(
            x: -bounds.width * 0.35, y: 0, width: bounds.width, height: bounds.height)
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.listView.animator().frame = bounds
            outgoing.animator().frame = NSRect(
                x: bounds.width, y: 0, width: bounds.width, height: bounds.height)
        }, completionHandler: { [weak self] in
            outgoing.removeFromSuperview()
            self?.isAnimating = false
            self?.view.needsLayout = true
        })
    }

    // MARK: - Mutations

    private func refreshList() {
        listView.setVariables(variables, referenced: referenced, visible: isVisible)
    }

    /// Append an empty variable, drill into it and focus its name field. The
    /// list's own "+" and the sidebar filter bar's "+" ▸ New Variable both
    /// land here.
    func addVariable() {
        let variable = QueryVariable(name: "", value: "", type: .literal)
        variables.append(variable)
        onChange?(variables)
        refreshList()
        drillIn(to: variable.id)
        detailVC?.focusNameField()
    }

    private func deleteVariable(_ id: UUID) {
        variables.removeAll { $0.id == id }
        onChange?(variables)
        if detailVC != nil {
            // The detail level was showing this variable; it is already gone
            // from `variables`, so `dismissDetail`'s own prune check finds
            // nothing to remove (the id lookup fails) and no-ops.
            dismissDetail(animated: true)
        } else {
            refreshList()
        }
    }

    private func variableEdited(_ updated: QueryVariable) {
        guard let index = variables.firstIndex(where: { $0.id == updated.id }) else { return }
        variables[index] = updated
        onChange?(variables)
        // Renaming or retyping can change whether this variable is a problem,
        // and can shadow or un-shadow another row. Only the detail level needs
        // updating here — the list is offscreen and is rebuilt by dismissDetail
        // on the way back, which is where other rows pick up the change.
        refreshDetailState()
    }
}
