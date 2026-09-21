import AppKit

/// Help menu actions — Pharos Help, Keyboard Shortcuts, Release Notes.
///
/// The addresses live in `AppInfo`, which Settings ▸ About also reads, so the
/// menu and the pane cannot drift apart.
extension AppDelegate {
    @objc func openPharosHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.keyboardShortcutsURL)
    }

    @objc func openReleaseNotes(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.releaseNotesURL)
    }
}
