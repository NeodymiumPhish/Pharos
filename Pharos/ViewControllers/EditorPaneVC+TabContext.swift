import AppKit

// The tab's context row: its connection › schema, what the connection is
// doing, and the transaction chip (which took the place of the banner above
// the cards). Everything here is this tab's, so it lives in the tab's pane.
extension EditorPaneVC {

    /// Fill the row from the tab, the connection records and the metadata.
    func refreshTabContext() {
        let tab = session.tab
        let connections = stateManager.connections
        let connectionId = tab?.connectionId
        let config = connectionId.flatMap { id in connections.first { $0.id == id } }

        tabContextBar.showConnections(
            connections.map { config in
                TabContextBar.ConnectionItem(
                    id: config.id, name: DisplayEscape.escaped(config.name),
                    state: TabConnectionState(connectionId: config.id, status: stateManager.status(for: config.id)))
            },
            selectedId: config?.id)

        let status = config.map { stateManager.status(for: $0.id) }
        let reason = status == .error
            ? config.flatMap { stateManager.connectionError(for: $0.id) }
                .map { DisplayEscape.escaped(SshTunnelAuthError.humanised($0)) }
            : nil
        tabContextBar.showState(TabContextState(connectionName: config?.name, status: status, failureReason: reason))

        let metadata = metadataCache.metadata(for: config?.id)
        let schemaState = SchemaButtonState(
            hasConnection: config != nil,
            isConnected: status == .connected,
            isLoading: metadata.isLoading,
            hasSchemas: !metadata.schemas.isEmpty,
            activeSchema: tab?.schemaName)
        tabContextBar.showSchema(title: schemaState.title, isEnabled: schemaState.isEnabled)

        refreshTransactionChip()
    }

    /// The chip: an open or failed transaction, or a reset. It ticks once a
    /// second while a transaction is open, for its age.
    func refreshTransactionChip() {
        let monitor = TabSessionMonitor.shared
        let state = session.activeTabId.flatMap { tabId in
            TabSessionBannerModel.state(
                report: monitor.report(for: tabId), receivedAt: monitor.receivedAt[tabId],
                pendingReset: monitor.pendingResets[tabId], now: Date())
        }
        tabContextBar.showTransaction(state)
        if case .transaction = state {
            if transactionChipTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshTransactionChip() }
                }
                timer.tolerance = 0.3
                RunLoop.main.add(timer, forMode: .common)
                transactionChipTimer = timer
            }
        } else {
            transactionChipTimer?.invalidate()
            transactionChipTimer = nil
        }
    }

    /// The chip's menu: what the state means, then what can be done about it.
    func transactionChipMenu() -> NSMenu? {
        let monitor = TabSessionMonitor.shared
        guard let tabId = session.activeTabId,
              let state = TabSessionBannerModel.state(
                report: monitor.report(for: tabId), receivedAt: monitor.receivedAt[tabId],
                pendingReset: monitor.pendingResets[tabId], now: Date()) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let info = NSMenuItem(title: state.message, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        for action in state.actions {
            let item = ClosureMenuItem(title: action.title) { [weak self] in self?.sessionBannerAction(action) }
            menu.addItem(item)
        }
        return menu
    }

    func wireTabContext() {
        tabContextBar.onChooseConnection = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didChooseConnection: id)
        }
        tabContextBar.onConnect = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPaneDidRequestConnect(self)
        }
        tabContextBar.onManageConnections = { ConnectionsManagerWindowController.show() }
        tabContextBar.onSchema = { [weak self] button in self?.presentSchemaPopover(from: button) }
        tabContextBar.transactionMenu = { [weak self] in self?.transactionChipMenu() }
    }

    // MARK: - Schema

    /// The tab's schema, and the window's schema-following state (the
    /// Database Navigator reads `activeSchema`).
    private func setTabSchema(_ schemaName: String?) {
        guard let tab = session.tab else { return }
        session.updateTab(id: tab.id) { $0.schemaName = schemaName }
        session.activeSchema = schemaName
    }

    private func presentSchemaPopover(from button: SchemaPopUpButton) {
        let connectionId = session.tab?.connectionId
        let schemaNames = metadataCache.metadata(for: connectionId).schemas.map(\.name)
        let defaultSchema = connectionId.flatMap { id in stateManager.connections.first { $0.id == id }?.defaultSchema }

        let vc = SchemaSelectorPopoverVC(schemas: schemaNames, activeSchema: session.tab?.schemaName,
                                         defaultSchema: defaultSchema)
        let popover = NSPopover()
        vc.onSelectSchema = { [weak self, weak popover] schema in
            self?.setTabSchema(schema)
            popover?.close()
        }
        vc.onSetDefault = { [weak self, weak popover] in
            self?.setDefaultSchema()
            popover?.close()
        }
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        // Pressed while open, released when it closes (`popoverDidClose`) —
        // the look AppKit gives a pop-up button while its menu is up.
        button.isPresenting = true
    }

    /// The tab's schema becomes its connection's default (nil — "All
    /// Schemas" — clears it). The connection store republishes, which
    /// refreshes the row.
    private func setDefaultSchema() {
        guard let connId = session.tab?.connectionId,
              var config = stateManager.connections.first(where: { $0.id == connId }) else { return }
        config.defaultSchema = session.tab?.schemaName
        stateManager.saveConnection(config)
    }
}
