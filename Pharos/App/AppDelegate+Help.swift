import AppKit

/// Help menu actions — Pharos Help, Keyboard Shortcuts, Release Notes.
extension AppDelegate {
    @objc func openPharosHelp(_ sender: Any?) {
        guard let url = URL(string: "https://neodymiumphish.github.io/Pharos/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        guard let url = URL(string: "https://neodymiumphish.github.io/Pharos/keyboard-shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openReleaseNotes(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/NeodymiumPhish/Pharos/releases") else { return }
        NSWorkspace.shared.open(url)
    }
}
