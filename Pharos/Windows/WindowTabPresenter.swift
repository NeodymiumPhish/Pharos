import AppKit
import Combine

/// Keeps a main window in step with its one query tab: the window title (which
/// is what the native tab shows), the subtitle "connection · schema", the
/// edited dot, the tab's tooltip, and the connection dot on the tab.
@MainActor
final class WindowTabPresenter {
    private weak var window: NSWindow?
    private let session: WindowSession
    private let stateManager = AppStateManager.shared
    private let dot = TabConnectionDot()
    private var cancellables = Set<AnyCancellable>()

    init(window: NSWindow, session: WindowSession) {
        self.window = window
        self.session = session
        window.tab.accessoryView = dot
        refresh()

        session.tabsSettled
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Publishers.CombineLatest(stateManager.$connections, stateManager.$connectionStatuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let window, let tab = session.tab else { return }
        let connectionName = tab.connectionId.flatMap { id in stateManager.connections.first { $0.id == id }?.name }
        let state = TabConnectionState(
            connectionId: connectionName == nil ? nil : tab.connectionId,
            status: tab.connectionId.map { stateManager.status(for: $0) })
        let context = TabConnectionState.subtitle(connectionName: connectionName, schema: tab.schemaName)

        if window.title != tab.name { window.title = tab.name }
        if window.subtitle != context { window.subtitle = context }
        window.isDocumentEdited = tab.isDirty
        window.tab.toolTip = "\(tab.name) — \(context) — \(state.label)"
        dot.state = state
        dot.isRunning = tab.isExecuting
    }
}
