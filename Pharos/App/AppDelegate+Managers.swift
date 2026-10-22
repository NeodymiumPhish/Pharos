import AppKit

// Window ▸ Tag Manager and Window ▸ Variable Manager, and the toolbar buttons
// that send the same actions. App-wide: they work with no main window.
extension AppDelegate {
    @MainActor @objc func menuShowVariableManager(_ sender: Any?) {
        VariableManagerWindowController.shared.show()
    }
}
