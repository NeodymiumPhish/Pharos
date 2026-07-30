import AppKit

/// Right-docked panel listing a tab's query variables, as two levels: a
/// read-only list, and a detail level for one variable. This controller owns the
/// variable array and the level swap; each level owns its own header and
/// rendering.
///
/// The panel is docked inside the white content area beside the editor, so it
/// uses the content background — matching the editor and inspector — rather than
/// the sidebar's edge vibrancy.
final class QueryVariablesPanelVC: NSViewController {

    /// Called whenever the variable set changes (add / delete / edit).
    var onChange: (([QueryVariable]) -> Void)?

    private(set) var variables: [QueryVariable] = []

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

    /// Replace the displayed variables and the referenced-name set (e.g. on tab
    /// switch). Returns to the list level, since the detail level belonged to
    /// whatever was showing before.
    ///
    /// Does NOT settle the outgoing detail level's name field itself — by the
    /// time this runs, the caller (`EditorPaneVC.syncVariablesPanel`, on the
    /// tab-switch path) has *already* moved its own bookkeeping of "which tab
    /// is active" on to the incoming tab, so a settle triggered from in here
    /// would misattribute the rename to the wrong tab. Callers that can
    /// change which tab is active must call `settlePendingEdit()` first,
    /// while their own notion of "current tab" (and `variables` below) still
    /// belongs to the outgoing one. `dismissDetail` still calls
    /// `settleForDismissal()` as a safety net for callers that don't (it's a
    /// no-op if this already ran), so a colliding draft is still dropped
    /// either way — only a *valid* rename depends on the caller settling
    /// first.
    func setVariables(_ vars: [QueryVariable], referenced: Set<String>) {
        variables = vars
        self.referenced = referenced
        dismissDetail(animated: false, pruningEmpty: false)
        refreshList()
    }

    /// Settles (commits if valid, drops if colliding) whatever the detail
    /// level's name field currently shows, without dismissing anything else —
    /// no level swap, no list rebuild. A no-op if the detail level isn't
    /// showing.
    ///
    /// This exists specifically for a caller that is about to change which
    /// tab is active (`EditorPaneVC.paneStateChanged`): it must call this
    /// *before* updating its own "which tab is this" state and before
    /// calling `setVariables` for the incoming tab. `variableEdited` below
    /// (which `settleForDismissal` -> `commitNameIfValid` -> `onChange`
    /// ultimately triggers) looks up the edited variable's id in `variables`
    /// — while that array, and the caller's own tab bookkeeping, still belong
    /// to the outgoing tab, the lookup succeeds and the rename lands on the
    /// right tab. Called even one step later than that — e.g. from inside
    /// `setVariables` itself, after `variables` and the caller's tab
    /// bookkeeping have already moved on — the same lookup would either fail
    /// silently (losing the rename) or, if that guard were ever relaxed,
    /// succeed against the *incoming* tab's array and land the outgoing
    /// tab's rename in the wrong tab's stored variables.
    func settlePendingEdit() {
        detailVC?.settleForDismissal()
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
        let container = PanelBackgroundView()
        container.wantsLayer = true
        self.view = container

        // Leading hairline so the panel edge reads cleanly against the editor.
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false

        contentArea.wantsLayer = true
        // The level-slide animation parallaxes the outgoing view to
        // `x = -bounds.width * 0.35` (see `push`/`pop` below). AppKit does not
        // clip subviews to their superview's bounds by default, so without
        // this the part that slides past the leading edge keeps drawing —
        // over the resize divider and into the editor beside the panel —
        // until the animation completes. `contentArea` is already
        // layer-backed, so `masksToBounds` is the minimal fix; `edge` (the
        // panel's leading hairline) and the split view's resize divider are
        // both siblings of `contentArea`, not its descendants, so this clip
        // cannot hide either of them.
        contentArea.layer?.masksToBounds = true
        contentArea.translatesAutoresizingMaskIntoConstraints = false

        listView.onAdd = { [weak self] in self?.addVariable() }
        listView.onSelect = { [weak self] id in self?.drillIn(to: id) }
        listView.onDelete = { [weak self] id in self?.deleteVariable(id) }
        contentArea.addSubview(listView)

        container.addSubview(edge)
        container.addSubview(contentArea)

        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: container.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
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
        detail.onBack = { [weak self] in self?.dismissDetail(animated: true, pruningEmpty: true) }
        addChild(detail)
        detailVC = detail
        refreshDetailState()

        push(detail.view)
    }

    /// Return to the list level. `pruningEmpty` discards a variable that is still
    /// empty in both name and value, so an abandoned `+` leaves no junk row.
    ///
    /// Every path here — `onBack` (which already settled via `attemptBack`
    /// before calling this), and every other path that tears the detail
    /// level down without going through it at all (a tab switch is the one
    /// that actually happened) — must settle the name field before reading
    /// `detail.variable` below. `settleForDismissal()` is a no-op if
    /// `attemptBack` already committed; it exists for the other paths, which
    /// cannot refuse to leave the way `attemptBack` can, so a valid typed
    /// name commits and a colliding one is simply dropped — there is nowhere
    /// to send the user back to argue about it. Settling first also means a
    /// freshly added row that was given a valid name here is no longer empty
    /// by the time the prune check below reads it, so it is correctly kept
    /// rather than pruned as abandoned.
    private func dismissDetail(animated: Bool, pruningEmpty: Bool) {
        guard let detail = detailVC else {
            listView.isHidden = false
            listView.frame = contentArea.bounds
            return
        }

        detail.settleForDismissal()

        let abandoned = detail.variable
        if pruningEmpty,
           abandoned.name.isEmpty,
           abandoned.value.isEmpty,
           variables.contains(where: { $0.id == abandoned.id }) {
            variables.removeAll { $0.id == abandoned.id }
            onChange?(variables)
        }

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
        listView.setVariables(variables, referenced: referenced)
    }

    private func addVariable() {
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
            // from `variables`, so nothing is left to prune.
            dismissDetail(animated: true, pruningEmpty: false)
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

/// Solid content-background panel that tracks light/dark. Uses `updateLayer`
/// (not a one-shot `layer.backgroundColor = ....cgColor`) so the semantic color
/// is re-resolved whenever the effective appearance changes.
private final class PanelBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
