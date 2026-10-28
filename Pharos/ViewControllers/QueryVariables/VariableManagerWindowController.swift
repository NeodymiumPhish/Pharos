import AppKit
import Combine

/// The Variable Manager: one window for the app-wide query variables, opened
/// from the toolbar, Window ▸ Variable Manager, a click on a `{{name}}` token,
/// the `{{` list's new-variable row, and a run that names an undefined one.
/// Edits go to `QueryVariableStore` as they are made; every window's editor
/// follows the store.
@MainActor
final class VariableManagerWindowController: NSWindowController, NSWindowDelegate {

    static let shared = VariableManagerWindowController()

    let managerVC = VariableManagerVC()
    private var cancellables = Set<AnyCancellable>()
    private var observer: NSObjectProtocol?

    /// The sidebar (220–320 pt) and the form (at least 460 pt) side by side.
    static let defaultSize = NSSize(width: 860, height: 560)
    static let minimumSize = NSSize(width: 720, height: 440)

    private init() {
        let window = UtilityWindow(autosaveName: "PharosVariableManagerWindow",
                                   title: String(localized: "Variable Manager"),
                                   defaultSize: Self.defaultSize,
                                   minimumSize: Self.minimumSize)
        super.init(window: window)
        window.contentViewController = managerVC
        // + and the filter field, before the window first draws.
        managerVC.installToolbar(on: window)
        // After the content controller, which resizes the window to its
        // fitting size; a remembered frame still wins.
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameUsingName("PharosVariableManagerWindow")
        window.delegate = self
        window.setAccessibilityIdentifier("window.variableManager")

        managerVC.onChange = { QueryVariableStore.shared.replace($0) }
        managerVC.choicesProvider = { Self.choices(for: $0) }
        observer = NotificationCenter.default.addObserver(
            forName: QueryVariableStore.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Compared first inside: this window's own edits come back here.
                    self?.managerVC.setVariables(QueryVariableStore.shared.variables)
                }
            }
        let state = AppStateManager.shared
        state.$connections.combineLatest(state.$connectionStatuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.managerVC.refreshChoices() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Show the window, on the variable called `name` when one is given (made
    /// when there is none).
    func show(variableNamed name: String? = nil) {
        _ = managerVC.view
        managerVC.setVariables(QueryVariableStore.shared.variables)
        if let name { managerVC.openVariable(named: name) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        managerVC.settlePendingEdit()
    }

    /// What a variable can be linked to (`VariableScope.linkTargets`), with
    /// each record's name, place and tile.
    static func choices(for variable: QueryVariable) -> [VariableConnectionsView.Choice] {
        let state = AppStateManager.shared
        let records = state.connections
        let connected = Set(state.connectionStatuses.filter { $0.value == .connected || $0.value == .connecting }.map(\.key))
        let targets = VariableScope.linkTargets(records: records, openIds: state.connectionIdsInUse.union(connected),
                                                linked: variable.connectionIds)
        return targets.map { target in
            guard let record = records.first(where: { $0.id == target.id }) else {
                return .init(id: target.id, name: "", place: "", kind: .file, state: .none, missing: true)
            }
            let kind: ConnectionTile.Kind
            switch ConnectionMenuText.kind(of: record) {
            case .server: kind = .server
            case .file: kind = .file
            case .memory: kind = .memory
            }
            return .init(id: record.id, name: DisplayEscape.escaped(record.name),
                         place: ConnectionMenuText.place(of: record), kind: kind,
                         state: TabConnectionState(connectionId: record.id, status: state.status(for: record.id)),
                         missing: false)
        }
    }
}
