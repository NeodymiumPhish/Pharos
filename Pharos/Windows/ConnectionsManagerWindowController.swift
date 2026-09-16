import AppKit

/// Presents `ConnectionsManagerVC` as a sheet on the main window.
///
/// It used to be a free-floating `NSWindow`. That window never adopted the
/// app's look: its two background plates were baked into their layers at
/// `loadView` time and so stayed light after a switch to Dark Mode, and it sat
/// outside the sheet vocabulary every other multi-field editor in Pharos uses
/// (`Pharos/Sheets/`). A sheet fixes both at once and costs only the things a
/// sheet cannot have — a saved frame, resizing, and staying open while the user
/// works in the editor behind it.
///
/// The type keeps its name and its `show()` API so every call site is unchanged.
enum ConnectionsManagerWindowController {

    /// The sheet on screen, if any. One at a time, whatever asks for it.
    @MainActor private static weak var presented: ConnectionsManagerVC?

    @MainActor
    static func show() {
        present(prefill: nil, passwordFromLink: false)
    }

    /// Opens the manager on a NEW, unsaved connection filled in from a
    /// `postgres://` link. Nothing is stored — the record is a stub in the list
    /// until the user presses Save.
    @MainActor
    static func show(prefill: ParsedConnectionURL) {
        present(prefill: config(from: prefill), passwordFromLink: prefill.passwordWasInURL)
    }

    @MainActor
    private static func present(prefill: ConnectionConfig?, passwordFromLink: Bool) {
        // Already up: bring its window forward and hand it the new stub, rather
        // than stacking a second sheet on the same window.
        if let existing = presented {
            existing.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let prefill {
                existing.beginNewConnection(prefilled: prefill, passwordFromLink: passwordFromLink)
            }
            return
        }

        // A sheet needs a host. A `postgres://` link can arrive with no window
        // at all — the app may not even be frontmost — so one is opened first.
        guard let host = hostWindowController() else { return }
        NSApp.activate(ignoringOtherApps: true)
        host.window?.makeKeyAndOrderFront(nil)

        guard let presenter = host.contentViewController else { return }
        let manager = ConnectionsManagerVC()
        presented = manager
        presenter.presentAsSheet(manager)
        if let prefill {
            manager.beginNewConnection(prefilled: prefill, passwordFromLink: passwordFromLink)
        }
    }

    /// The window to hang the sheet on. `showMainWindow()` already answers
    /// "the one the user is in, opening one when the app has none on screen",
    /// which is exactly what a `postgres://` link arriving at a hidden app
    /// needs.
    @MainActor
    private static func hostWindowController() -> MainWindowController? {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    /// The link's fields as a connection record. The mapping lives here, not in
    /// `ConnectionURLParser`: the parser stays Foundation-only so its rules can
    /// be unit tested without AppKit.
    @MainActor
    private static func config(from parsed: ParsedConnectionURL) -> ConnectionConfig {
        var config = ConnectionConfig(
            id: UUID().uuidString,
            name: parsed.suggestedName,
            host: parsed.host,
            // libpq's default, and the form's.
            port: parsed.port ?? 5432,
            database: parsed.database ?? "",
            username: parsed.user ?? "",
            password: parsed.password ?? ""
        )
        // An exhaustive switch, so a mode added to the parser cannot be dropped
        // here without the build saying so. `nil` leaves the record's default.
        switch parsed.sslMode {
        case .disable: config.sslMode = .disable
        case .prefer:  config.sslMode = .prefer
        case .require: config.sslMode = .require
        case nil:      break
        }
        return config
    }
}
