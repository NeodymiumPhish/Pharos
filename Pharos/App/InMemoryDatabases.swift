import AppKit

/// In-memory DuckDB databases (F7): the question before their tables are
/// lost, and Save In-Memory Database….
///
/// An in-memory database has no other copy, so Disconnect, Quit and Delete
/// ALWAYS ask when it holds tables or views of its own — whatever Settings ▸
/// "Warn before closing unsaved tabs" says (owner decision 6). The wording
/// follows the unsaved-work alert: Save…, Don't Save, Cancel.
@MainActor
enum InMemoryDatabases {

    enum Action { case disconnect, quit }

    /// The in-memory records that are connected now, in list order.
    static func connected(_ ids: [String]? = nil) -> [ConnectionConfig] {
        let manager = AppStateManager.shared
        return manager.connections.filter { config in
            config.isInMemoryDuckDB && manager.status(for: config.id) == .connected
                && (ids?.contains(config.id) ?? true)
        }
    }

    /// The alert's text for `count` tables and views; nil count = the count
    /// did not come back in time (ask without a number).
    static func lossText(count: UInt64?) -> String {
        switch count {
        case nil: return String(localized: "Its tables and views are lost if you don't save them.")
        case 1?: return String(localized: "It holds 1 table or view, which is lost if you don't save it.")
        case let n?: return String(localized: "It holds \(String(n)) tables and views, which are lost if you don't save them.")
        }
    }

    /// Ask about each record in turn, stopping at the first Cancel. `then`
    /// is called exactly once: true to go on (each one saved or not wanted),
    /// false for Cancel or a failed save.
    static func confirmLoss(of records: [ConnectionConfig], window: NSWindow?, action: Action,
                            then: @escaping (Bool) -> Void) {
        guard let record = records.first else { then(true); return }
        let rest = Array(records.dropFirst())
        Task { @MainActor in
            // A short wait at most: the core gives up after 3 s, and then the
            // question is asked without a number.
            let count = try? await PharosCore.duckUserTableCount(connectionId: record.id)
            if count == 0 {
                confirmLoss(of: rest, window: window, action: action, then: then)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Do you want to save the in-memory database “\(DisplayEscape.escapedTrimmed(record.name))”?")
            alert.informativeText = lossText(count: count)
            alert.addButton(withTitle: String(localized: "Save…"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
            cancel.keyEquivalent = "\u{1b}"
            let answer: (NSApplication.ModalResponse) -> Void = { response in
                switch response {
                case .alertFirstButtonReturn:
                    save(record, window: window, offerOpen: false) { saved in
                        if saved { confirmLoss(of: rest, window: window, action: action, then: then) } else { then(false) }
                    }
                case .alertSecondButtonReturn:
                    confirmLoss(of: rest, window: window, action: action, then: then)
                default:
                    then(false)
                }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
        }
    }

    /// Save an in-memory database to a new file. The panel says what the
    /// copy leaves out. `offerOpen`: after the save, offer to open the file
    /// in a new tab (File ▸ Save In-Memory Database…); the tabs on the
    /// in-memory database stay where they are.
    static func save(_ record: ConnectionConfig, window: NSWindow?, offerOpen: Bool, then: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DuckDBFiles.contentType]
        panel.nameFieldStringValue = DataFiles.identifier(from: record.name, fallback: "database") + ".duckdb"
        panel.prompt = String(localized: "Save")
        panel.message = String(localized: "The copy has the tables and views and their data. It leaves out temporary tables, attached PostgreSQL databases and work not yet committed in other tabs.")
        let guardDelegate = DuckDBNewPanelDelegate()
        panel.delegate = guardDelegate
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            withExtendedLifetime(guardDelegate) {}
            guard response == .OK, let url = panel.url else { then(false); return }
            // The panel asked about replacing; the old file goes to the Trash
            // (a file Pharos has open was refused by the delegate).
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                    NSAlert(error: error).runModal()
                    then(false)
                    return
                }
            }
            Task { @MainActor in
                do {
                    try await PharosCore.duckSaveInMemory(connectionId: record.id, filePath: url.path)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The database was not saved.")
                    alert.informativeText = DisplayEscape.escaped(error.localizedDescription)
                    alert.runModal()
                    then(false)
                    return
                }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                if offerOpen {
                    let done = NSAlert()
                    done.messageText = String(localized: "Saved “\(DisplayEscape.escaped(url.lastPathComponent))”.")
                    done.informativeText = String(localized: "Open the saved file in a new tab? The tabs on the in-memory database stay as they are.")
                    done.addButton(withTitle: String(localized: "Open"))
                    done.addButton(withTitle: String(localized: "Not Now"))
                    if done.runModal() == .alertFirstButtonReturn {
                        (NSApp.delegate as? AppDelegate)?.openDuckDBFile(url)
                    }
                }
                then(true)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }
}
