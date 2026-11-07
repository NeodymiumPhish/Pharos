import AppKit

// Window ▸ Tag Manager, Window ▸ Variable Manager, File ▸ Manage
// Connections…, File ▸ Export App Data… and File ▸ Import App Data…, and the
// toolbar buttons that send the same actions.
// App-wide: they work with no main window, and from a manager window, whose
// responder chain reaches no MainWindowController.
extension AppDelegate {
    @MainActor @objc func menuShowConnectionsManager(_ sender: Any?) {
        ConnectionsManagerWindowController.show()
    }

    @MainActor @objc func menuShowVariableManager(_ sender: Any?) {
        VariableManagerWindowController.shared.show()
    }

    @MainActor @objc func menuExportAppData(_ sender: Any?) {
        AppDataTransferWindowController.shared.showExport()
    }

    @MainActor @objc func menuImportAppData(_ sender: Any?) {
        AppDataTransferWindowController.shared.showImport()
    }

    /// The front tab's loaded results go behind the live match count.
    @MainActor @objc func menuShowTagManager(_ sender: Any?) {
        let inputs = frontmostWindowController?.splitViewController.contentVC.tagManagerInputs()
        TagManagerWindowController.shared.show(columns: inputs?.columns ?? [], loadedRows: inputs?.loadedRows ?? ResultTable())
    }
}
