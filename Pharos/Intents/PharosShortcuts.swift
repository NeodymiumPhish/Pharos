import AppIntents

/// The two actions that are worth a spoken phrase and a place in the Shortcuts
/// gallery without the user building anything first.
///
/// Every phrase names `\(.applicationName)` — the system requires it, so Siri
/// can tell "run a saved query" in Pharos from the same words meant for another
/// app. The parameter-carrying phrases need their entity queries to be
/// `EntityStringQuery`, which is why `ConnectionQuery` matches on text as well
/// as on id.
struct PharosShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConnectionIntent(),
            phrases: [
                "Open \(.applicationName) connection",
                "Connect to \(\.$connection) in \(.applicationName)"
            ],
            shortTitle: "Open Connection",
            systemImageName: "cylinder.split.1x2"
        )
        AppShortcut(
            intent: RunSavedQueryIntent(),
            phrases: [
                "Run a saved query in \(.applicationName)",
                "Run \(\.$query) in \(.applicationName)"
            ],
            shortTitle: "Run Saved Query",
            systemImageName: "play.rectangle"
        )
    }
}
