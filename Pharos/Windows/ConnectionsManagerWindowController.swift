import AppKit

/// The Connections Manager: one window for every saved connection, with the
/// list in a Liquid Glass sidebar and the chosen record's form beside it.
///
/// It was a sheet for a while, because the free-floating window before it
/// baked its background plates into their layers at `loadView` time and so
/// stayed light after a switch to Dark Mode. The window is back with the cause
/// gone: the shared manager shell (`ManagerSplitViewController`) and the
/// Settings furniture resolve every colour at draw time. As a window it has
/// what a sheet could not — a remembered frame, resizing, and staying open
/// while the user works in the editor behind it.
///
/// The static `show()` / `show(prefill:)` API is unchanged, so every call
/// site is too.
@MainActor
final class ConnectionsManagerWindowController: NSWindowController {

    static let shared = ConnectionsManagerWindowController()

    static let autosaveName = "PharosConnectionsManagerWindow"
    static let defaultSize = NSSize(width: 980, height: 720)
    static let minimumSize = NSSize(width: 820, height: 560)

    let managerVC = ConnectionsManagerVC()

    private init() {
        let window = UtilityWindow(autosaveName: Self.autosaveName,
                                   title: String(localized: "Connections"),
                                   defaultSize: Self.defaultSize,
                                   minimumSize: Self.minimumSize)
        super.init(window: window)
        window.contentViewController = managerVC
        // After the content controller, which resizes the window to its
        // fitting size; a remembered frame still wins.
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameUsingName(Self.autosaveName)
        window.setAccessibilityIdentifier("window.connectionsManager")
        // Before the window is first on screen, so it never draws without
        // its toolbar.
        managerVC.installToolbarIfNeeded(on: window)
        // Closing with unsaved edits asks first. False keeps the window open;
        // the prompt closes it itself once the user has answered.
        window.shouldClose = { [weak self, weak window] in
            guard let self, let window else { return true }
            return self.managerVC.confirmClose(in: window) { [weak window] in window?.close() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Showing

    static func show() {
        shared.present(prefill: nil, passwordFromLink: false)
    }

    /// Opens the manager on a NEW, unsaved connection filled in from a
    /// `postgres://` link. Nothing is stored — the record is a stub in the list
    /// until the user presses Save.
    static func show(prefill: ParsedConnectionURL) {
        shared.present(prefill: config(from: prefill), passwordFromLink: prefill.passwordWasInURL)
    }

    /// Bring the window forward, and begin the new connection when there is
    /// one. Already open: the same window comes forward and takes the new
    /// stub — after the unsaved-work prompt, if the form has edits.
    private func present(prefill: ConnectionConfig?, passwordFromLink: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let prefill {
            managerVC.beginNewConnection(prefilled: prefill, passwordFromLink: passwordFromLink)
        }
    }

    /// The link's fields as a connection record. The mapping lives here, not in
    /// `ConnectionURLParser`: the parser stays Foundation-only so its rules can
    /// be unit tested without AppKit.
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
