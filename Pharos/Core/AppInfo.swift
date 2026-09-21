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

    /// The build number — "1". Empty when the key is missing, which is what
    /// drops the parentheses from `versionLine(from:)`.
    static func build(from info: [String: Any]) -> String {
        (info["CFBundleVersion"] as? String) ?? ""
    }

    /// "Version 0.1.0 (1)", or "Version 0.1.0" when there is no build number.
    static func versionLine(from info: [String: Any]) -> String {
        let version = self.version(from: info)
        let build = self.build(from: info)
        guard !build.isEmpty else { return String(localized: "Version \(version)") }
        return String(localized: "Version \(version) (\(build))")
    }

    // MARK: - This build

    static var name: String { name(from: Bundle.main.infoDictionary ?? [:]) }
    static var version: String { version(from: Bundle.main.infoDictionary ?? [:]) }
    static var build: String { build(from: Bundle.main.infoDictionary ?? [:]) }
    static var versionLine: String { versionLine(from: Bundle.main.infoDictionary ?? [:]) }
}
