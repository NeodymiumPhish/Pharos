import AppKit

/// Settings ▸ About. What this build of Pharos is, and where Pharos lives on
/// the web.
///
/// This pane replaces the system About panel. That panel is a second window
/// AppKit builds from `Info.plist`, and nothing can be added to it — not the
/// repository, not a link of any kind. Settings is already the app-wide window
/// that opens with no document window on screen, so About belongs in it.
///
/// Pharos ▸ About Pharos opens the Settings window here (see
/// `SettingsWindowController.show(pane:)`). It arrives as a deep link, so ⌘,
/// still returns to the pane the user was working in.
final class AboutSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .about) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The app icon, the name and the version line.
    ///
    /// `NSApp.applicationIconImage` rather than `NSImage(named: "AppIcon")`:
    /// it is the icon macOS is actually showing for this build, so a scratch
    /// copy with an icon of its own reports itself honestly.
    override var headerViews: [NSView] {
        [SettingsAboutHeader(icon: NSApp.applicationIconImage,
                             name: AppInfo.name,
                             versionLine: AppInfo.versionLine)]
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    override var sections: [SettingsSection] {
        [
            SettingsSection(
                title: String(localized: "Links"),
                items: [
                    SettingsItem(
                        id: "repository",
                        title: String(localized: "Source code"),
                        caption: AppInfo.repositoryLabel,
                        icon: "chevron.left.forwardslash.chevron.right",
                        help: String(localized: "Pharos is built in the open. The repository holds the source, the issue tracker and every release."),
                        kind: .action(title: String(localized: "View on GitHub"), destructive: false) { [weak self] in
                            self?.open(AppInfo.repositoryURL)
                        }),
                    SettingsItem(
                        id: "help",
                        title: String(localized: "Pharos Help"),
                        caption: String(localized: "The user guide, in your browser."),
                        icon: "questionmark.circle",
                        kind: .action(title: String(localized: "Open Help"), destructive: false) { [weak self] in
                            self?.open(AppInfo.helpURL)
                        }),
                    SettingsItem(
                        id: "releaseNotes",
                        title: String(localized: "Release notes"),
                        caption: String(localized: "What changed in each version."),
                        icon: "sparkles",
                        help: String(localized: "Settings ▸ General decides whether Pharos looks for a new version by itself."),
                        kind: .action(title: String(localized: "Open Release Notes"), destructive: false) { [weak self] in
                            self?.open(AppInfo.releaseNotesURL)
                        }),
                ]),
            SettingsSection(
                title: String(localized: "Acknowledgements"),
                items: [
                    SettingsItem(
                        id: "duckdb",
                        title: "DuckDB",
                        caption: String(localized: "DuckDB \(PharosCore.duckDBVersion()) with the icu, inet, fts, excel, sqlite, postgres, httpfs, json, parquet and autocomplete extensions, and duckdb-rs. MIT License, Stichting DuckDB Foundation."),
                        icon: "cylinder.split.1x2",
                        kind: .display),
                    SettingsItem(
                        id: "thirdPartyNotices",
                        title: String(localized: "Third-party notices"),
                        caption: String(localized: "Pharos contains open-source software: DuckDB and the libraries it uses, and the Rust crates of its engine. The notices give each one's licence."),
                        icon: "doc.text",
                        kind: .action(title: String(localized: "Show Notices"), destructive: false) { [weak self] in
                            guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") else { return }
                            self?.open(url)
                        }),
                ]),
        ]
    }
}
