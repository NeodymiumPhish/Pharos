import AppKit

/// Saved Sessions. A saved query is a saved Session: the tab's cards AND the
/// result each card holds, rows and all (`saved_query_results` in
/// pharos-core). This file writes a tab's results into its Session and puts a
/// Session's results back on a tab's cards. The decisions — which results go,
/// in what order, and which card each comes back to — are `SessionSnapshot`'s.
extension ContentViewController {

    // MARK: - Saving

    /// One Session write at a time, app-wide: two tabs can name the same
    /// Session (the Save sheet's Replace), and their snapshots must not
    /// interleave.
    private static let sessionWriteQueue = DispatchQueue(label: "com.pharos.session-write", qos: .userInitiated)

    /// Tabs whose Session write is running. A second ⌘S waits for the first.
    static var sessionWritesInFlight = Set<String>()

    /// Write tab `tabId`'s cards and the results it holds into Session
    /// `savedQueryId`. `completion(true)` once the Session is stored.
    ///
    /// The tab's state is captured here, on the main thread: the results are
    /// copy-on-write values, so the capture is cheap and a run that lands
    /// during the write cannot change what is written. The encoding,
    /// compression and SQLite work happen on `sessionWriteQueue`.
    func writeSession(tabId: String, savedQueryId: String, reportErrors: Bool = true,
                      completion: @escaping (Bool) -> Void) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { completion(false); return }
        let document = tab.document
        let stored = CardPersistence.encode(document, mode: .latest)
        let held = session.resultStore[tabId].results.filter(\.hasPayload)
        let connectionId = tab.connectionId
        let schemaName = tab.schemaName
        let tabName = tab.name
        Self.sessionWritesInFlight.insert(tabId)

        Self.sessionWriteQueue.async {
            let outcome = Result {
                try Self.writeSnapshot(savedQueryId: savedQueryId, document: document, text: stored.text,
                                       json: stored.json, held: held, connectionId: connectionId,
                                       schemaName: schemaName)
            }
            DispatchQueue.main.async { [weak self] in
                Self.sessionWritesInFlight.remove(tabId)
                switch outcome {
                case .success(let committed):
                    self?.sessionWritten(tabId: tabId, document: document, committed: committed)
                    completion(true)
                case .failure(let error):
                    Log.query.error("Failed to save the Session: \(error.localizedDescription, privacy: .public)")
                    if reportErrors {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Couldn't save “\(tabName)”")
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: String(localized: "OK"))
                        alert.runModal()
                    }
                    completion(false)
                }
            }
        }
    }

    /// Stage each result, then commit; on any failure, discard what was
    /// staged. The Session's stored snapshot is untouched until the commit.
    private static func writeSnapshot(savedQueryId: String, document: CardDocument, text: String, json: String?,
                                      held: [CardResult], connectionId: String?,
                                      schemaName: String?) throws -> CommittedSavedQuerySnapshot {
        let storedRunIds = Set(try PharosCore.loadSavedQueryResults(savedQueryId: savedQueryId)
            .filter { $0.hasRows || $0.kind == .affected }
            .map(\.runId))
        let plan = SessionSnapshot.plan(
            document: document,
            held: held.map { SessionSnapshot.Held(cardId: $0.id, timestamp: $0.timestamp) },
            storedRunIds: storedRunIds)
        let byCard = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshotId = UUID().uuidString
        do {
            for item in plan.stage {
                guard let result = byCard[item.cardId], let run = document.card(item.cardId)?.lastRun else { continue }
                _ = try PharosCore.stageSavedQueryResult(stageRow(
                    result, run: run, priority: item.priority, savedQueryId: savedQueryId,
                    snapshotId: snapshotId, schemaName: schemaName))
            }
            return try PharosCore.commitSavedQuerySnapshot(CommitSavedQuerySnapshot(
                savedQueryId: savedQueryId, snapshotId: snapshotId, sql: text, cardsJson: json,
                connectionId: connectionId, schemaName: schemaName, keep: plan.keep))
        } catch {
            try? PharosCore.abortSavedQuerySnapshot(savedQueryId: savedQueryId, snapshotId: snapshotId)
            throw error
        }
    }

    private static func stageRow(_ result: CardResult, run: CardRunRecord, priority: Int, savedQueryId: String,
                                 snapshotId: String, schemaName: String?) -> StageSavedQueryResult {
        let rows = result.queryResult
        return StageSavedQueryResult(
            savedQueryId: savedQueryId, snapshotId: snapshotId, runId: run.runId, cardId: result.id,
            priority: priority, kind: rows != nil ? .rows : .affected,
            sql: result.sql, rawSql: result.rawSQL, schemaName: result.historySchema ?? schemaName,
            executedAt: ISO8601DateFormatter().string(from: run.finishedAt),
            executionTimeMs: result.executionTimeMs, rowsAffected: result.executeResult?.rowsAffected,
            rowCount: rows?.rows.count, hasMore: rows?.hasMore ?? false,
            chartViewStateJson: chartStateJSON(of: result),
            columns: rows?.columns, rows: rows?.rows, rowIdentity: rows?.rowIdentity)
    }

    /// The chart and view mode, as the history row stores them. Nil for a
    /// plain grid with no chart.
    private static func chartStateJSON(of result: CardResult) -> String? {
        guard result.chartConfig != nil || result.resultViewMode != .grid,
              let data = try? JSONEncoder.pharos.encode(
                PersistedResultViewState(chartConfig: result.chartConfig, viewMode: result.resultViewMode))
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The write landed. The tab is clean only when nothing changed while it
    /// ran: an edit or a run during the write is not in the Session.
    private func sessionWritten(tabId: String, document: CardDocument, committed: CommittedSavedQuerySnapshot) {
        session.updateTab(id: tabId) {
            if $0.document == document { $0.isDirty = false }
        }
        NotificationCoalescer.post(.savedQueriesDidChange)
        guard !committed.droppedRunIds.isEmpty else { return }
        let n = committed.droppedRunIds.count
        let alert = NSAlert()
        alert.messageText = n == 1
            ? String(localized: "1 result was saved without its rows")
            : String(localized: "\(n) results were saved without their rows")
        alert.informativeText = String(localized: "A Session can keep \(ByteCountFormatter.string(fromByteCount: 100 * 1024 * 1024, countStyle: .file)) of results. The queries were saved; run them again after you open the Session.")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A Session tab's results changed (a run, Load More or Load All): they
    /// are no longer the ones the Session stores, so the tab is unsaved and
    /// closing it asks first. A tab bound to no Session is left alone:
    /// results are not part of a file or a scratch tab.
    ///
    /// Clear Results does not call this. It frees memory, as the result
    /// limit does, and a save keeps the stored rows of a result that is no
    /// longer in memory (`SessionSnapshot.plan`'s keep list) — so the Session
    /// has not changed.
    ///
    /// Chart and view-mode changes do not call this. Their setters also run
    /// while a restore shows a saved chart, which would mark a tab the user
    /// has only opened. The next save stores them all the same.
    func markSessionResultsChanged(tabId: String) {
        session.updateTab(id: tabId) {
            if $0.savedQueryId != nil { $0.isDirty = true }
        }
    }

    // MARK: - Restoring

    /// Put the results saved with Session `savedQueryId` back on tab `tabId`'s
    /// cards. The tab is already open: this only fills it in.
    ///
    /// A card gets its stored result only while its run is still the saved
    /// one (`SessionSnapshot.match`), so a card run again while this loaded
    /// keeps its new result. A result the tab already holds for that same
    /// run is replaced only when it came from history — a relaunched tab with
    /// a workspace gets the history copy first, which holds the first page
    /// alone, while the Session holds every row that was saved. A result of
    /// the run itself, or one with pending cell edits, stays.
    func restoreSessionResults(tabId: String, savedQueryId: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let metas = try? PharosCore.loadSavedQueryResults(savedQueryId: savedQueryId),
                  !metas.isEmpty else { return }
            // One FFI round trip per result: each can be large.
            var rows: [String: QueryHistoryResultData] = [:]
            for meta in metas where meta.kind == .rows && meta.hasRows {
                if let data = try? PharosCore.getSavedQueryResult(id: meta.id) { rows[meta.id] = data }
            }
            let loaded = rows
            await MainActor.run { [weak self] in
                self?.applySessionResults(metas: metas, rows: loaded, tabId: tabId)
            }
        }
    }

    private func applySessionResults(metas: [SavedQueryResultMeta], rows: [String: QueryHistoryResultData],
                                     tabId: String) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return }
        let match = SessionSnapshot.match(document: tab.document, metas: metas)
        var entry = session.resultStore[tabId]
        var restored: [CardResult] = []
        var removed = match.removed
        for card in tab.document.cards {
            guard let meta = match.results[card.id], let run = card.lastRun else { continue }
            let held = entry.result(forCard: card.id)
            if let held, held.runId == run.runId || !held.pendingEdits.isEmpty { continue }
            guard var result = Self.sessionResult(meta, rows: rows[meta.id], card: card.id, run: run) else {
                if held == nil { removed.insert(card.id) }
                continue
            }
            // Chart changes and renames go on writing to the history row.
            result.historyResultId = held?.historyResultId
            restored.append(result)
        }
        // A replaced result keeps its place. The rest go first: the store
        // lists oldest first and the result limit lets go of the oldest, so
        // saved results go before anything run since the tab opened.
        var fresh: [CardResult] = []
        for result in restored.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let i = entry.results.firstIndex(where: { $0.id == result.id }) {
                entry.results[i] = result
            } else {
                fresh.append(result)
            }
        }
        entry.results.insert(contentsOf: fresh, at: 0)
        session.resultStore[tabId] = entry

        let restoredIds = Set(restored.map(\.id))
        session.updateTab(id: tabId) { t in
            for i in t.document.cards.indices {
                let id = t.document.cards[i].id
                if restoredIds.contains(id) {
                    t.document.cards[i].resultsRemoved = false
                } else if removed.contains(id), entry.result(forCard: id) == nil {
                    t.document.cards[i].resultsRemoved = true
                }
            }
        }
        applySeededResultState(forTabId: tabId)
    }

    /// A card's result from its stored copy. Nil when the rows should be
    /// there and are not.
    private static func sessionResult(_ meta: SavedQueryResultMeta, rows: QueryHistoryResultData?, card: String,
                                      run: CardRunRecord) -> CardResult? {
        let executedAt = ISO8601DateFormatter().date(from: meta.executedAt) ?? run.finishedAt
        var result = CardResult(cardId: card, runId: run.runId, sql: meta.sql, rawSQL: meta.rawSql ?? meta.sql,
                                timestamp: executedAt)
        let ms = UInt64(max(0, meta.executionTimeMs))
        result.executionTimeMs = ms
        // The banner shows the schema the rows came from, as for history.
        result.historySchema = meta.schemaName
        // The user saw these rows before they saved them; the result limit
        // must not treat them as never looked at.
        result.hasBeenViewed = true
        switch meta.kind {
        case .rows:
            guard let rows else { return nil }
            result.queryResult = .fromSavedSession(rows, hasMore: meta.hasMore, executionTimeMs: ms)
            result.totalRowCountHint = meta.hasMore ? nil : rows.rows.count
        case .affected:
            result.executeResult = ExecuteResult(rowsAffected: UInt64(max(0, meta.rowsAffected ?? 0)),
                                                 executionTimeMs: ms, historyEntryId: nil)
        }
        if let json = meta.chartViewStateJson, let data = json.data(using: .utf8),
           let state = try? JSONDecoder.pharos.decode(PersistedResultViewState.self, from: data) {
            result.chartConfig = state.chartConfig
            result.resultViewMode = state.viewMode
        }
        return result
    }
}
