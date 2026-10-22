import AppKit

// Window ▸ Tag Manager and Window ▸ Variable Manager, and the toolbar buttons
// that send the same actions. App-wide: they work with no main window.
extension AppDelegate {
    @MainActor @objc func menuShowVariableManager(_ sender: Any?) {
        VariableManagerWindowController.shared.show()
    }

    /// The front tab's loaded results go behind the live match count.
    @MainActor @objc func menuShowTagManager(_ sender: Any?) {
        let inputs = frontmostWindowController?.splitViewController.contentVC.tagManagerInputs()
        TagManagerWindowController.shared.show(columns: inputs?.columns ?? [], loadedRows: inputs?.loadedRows ?? [])
    }
}
