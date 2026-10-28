import AppKit

// Window ▸ Tag Manager, Window ▸ Variable Manager, File ▸ Manage
// Connections…, and the toolbar buttons that send the same actions.
// App-wide: they work with no main window, and from a manager window, whose
// responder chain reaches no MainWindowController.
extension AppDelegate {
    @MainActor @objc func menuShowConnectionsManager(_ sender: Any?) {
        ConnectionsManagerWindowController.show()
    }

    @MainActor @objc func menuShowVariableManager(_ sender: Any?) {
        VariableManagerWindowController.shared.show()
    }

    /// The front tab's loaded results go behind the live match count.
    @MainActor @objc func menuShowTagManager(_ sender: Any?) {
        let inputs = frontmostWindowController?.splitViewController.contentVC.tagManagerInputs()
        TagManagerWindowController.shared.show(columns: inputs?.columns ?? [], loadedRows: inputs?.loadedRows ?? [])
    }
}
