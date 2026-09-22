import Foundation

/// What this build of Pharos is, and where Pharos lives on the web.
///
/// Foundation only, and every string is derived from an info dictionary that
/// the caller supplies, so `scripts/test-app-info.sh` compiles and tests it
/// with no bundle, no AppKit and no FFI. The `Bundle.main` conveniences are
/// thin wrappers for the app to use.
enum AppInfo {

    // MARK: - Where Pharos lives

    /// The source repository. Shown in Settings ▸ About.
    static let repositoryURL = URL(string: "https://github.com/NeodymiumPhish/Pharos")!

    /// The user guide. Also Help ▸ Pharos Help.
    static let helpURL = URL(string: "https://neodymiumphish.github.io/Pharos/")!

    /// The shortcut reference. Help ▸ Keyboard Shortcuts.
    static let keyboardShortcutsURL = URL(string: "https://neodymiumphish.github.io/Pharos/keyboard-shortcuts")!

    /// The published releases. Also Help ▸ Release Notes.
    static let releaseNotesURL = URL(string: "https://github.com/NeodymiumPhish/Pharos/releases")!

    /// The repository without its scheme, for a caption that must stay short.
    static let repositoryLabel = "github.com/NeodymiumPhish/Pharos"

    // MARK: - What this build is

    /// The name to show. `CFBundleDisplayName` first, because that is the one
    /// a localisation replaces.
    static func name(from info: [String: Any]) -> String {
        (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Pharos"
    }

    /// The marketing version — "0.1.0". The fallback is the one
    /// `UpdateChecker` already uses for the same key, so a build with no
    /// version compares as older than every release rather than crashing.
    static func version(from info: [String: Any]) -> String {
        (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// "Version 0.1.0".
    ///
    /// The marketing version alone. `CFBundleVersion` is NOT appended: the
    /// release process gives both keys the same number, so the parenthetical
    /// only ever repeated what the line already said ("Version 2.6.205
    /// (2.6.205)").
    static func versionLine(from info: [String: Any]) -> String {
        String(localized: "Version \(version(from: info))")
    }

    // MARK: - This build

    static var name: String { name(from: Bundle.main.infoDictionary ?? [:]) }
    static var version: String { version(from: Bundle.main.infoDictionary ?? [:]) }
    static var versionLine: String { versionLine(from: Bundle.main.infoDictionary ?? [:]) }
}
