import AppKit

/// Where a card is in its tab's run queue.
enum CardRunPhase: String {
    case idle
    case queued
    case running
    /// The destructive-SQL confirmation is on screen.
    case awaitingConfirmation = "awaiting_confirmation"
}

enum CardCancelOutcome {
    case removedFromQueue
    case cancelling
    /// The confirmation sheet is up: only the user can answer it.
    case awaitingConfirmation
    case notRunning
}

/// What an MCP client's tool calls do to a window (`MCPToolHandlers`). Every
/// change goes through the tab's document and the same views a keystroke
/// does, so the user sees the client's cards appear and run.
extension ContentViewController {

    /// A client added or changed cards in `tabId`: rebuild the stack if it
    /// is on screen, keep `anchor` in view, and mark the tab unsaved.
    func agentChangedCards(inTab tabId: String, anchor: String?) {
        session.updateTab(id: tabId) { $0.isDirty = true }
        guard editorPane.showsTab(tabId) else { return }
        editorPane.reloadCards(anchor: anchor)
        if let anchor { editorPane.cardStack.scrollToCard(anchor) }
    }

    /// Say in the window what a client did.
    func showAgentNotice(_ message: String, duration: TimeInterval = 3.0, onClick: (() -> Void)? = nil) {
        guard isViewLoaded else { return }
        Toast.show(in: view, message: message, style: .info, duration: duration, onClick: onClick)
    }

    /// A client's run waits on the destructive confirmation: put its window in
    /// front of the other Pharos windows and bounce the Dock icon. Pharos is
    /// not made the active app — the user may be typing elsewhere — but the
    /// sheet must not sit unseen.
    func bringForwardForAgentConfirmation(_ agent: MCPClientInfo) {
        (NSApp.delegate as? AppDelegate)?.front(session)
        NSApp.requestUserAttention(.criticalRequest)
        Log.ui.info("MCP run from \(agent.displayName, privacy: .public) waits for confirmation")
    }

    /// Save tab `tabId` as a new Session, the way the Save sheet's Save does,
    /// without the sheet. `completion` gets the Session, or an error message.
    func saveAsNewSession(tabId: String, name: String, folder: String?,
                          completion: @escaping (Result<SavedQuery, MCPToolError>) -> Void) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else {
            completion(.failure(.notFound("That tab is closed.")))
            return
        }
        let stored = CardPersistence.encode(tab.document, mode: .latest)
        let create = CreateSavedQuery(name: name, folder: folder, sql: stored.text, connectionId: nil,
                                      variables: nil, cardsJson: stored.json)
        let saved: SavedQuery
        do {
            saved = try PharosCore.createSavedQuery(create)
        } catch {
            completion(.failure(.failed("Pharos could not save the Session: \(error.localizedDescription)")))
            return
        }
        session.updateTab(id: tabId) {
            $0.savedQueryId = saved.id
            $0.name = saved.name
            $0.nameIsCustom = true
        }
        writeSession(tabId: tabId, savedQueryId: saved.id, reportErrors: false) { ok in
            completion(ok ? .success(saved)
                          : .failure(.failed("The Session “\(saved.name)” was created, but its cards and results could not be written. Try save_session again.")))
        }
    }
}
