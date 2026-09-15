import AppKit

/// Free-floating window that hosts ConnectionsManagerVC. Singleton — calling
/// `show()` repeatedly brings the existing window forward instead of stacking.
final class ConnectionsManagerWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: ConnectionsManagerWindowController?
    private static let frameAutosaveKey = "PharosConnectionsManager"

    @MainActor
    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = ConnectionsManagerWindowController()
        shared = wc
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the window on a NEW, unsaved connection filled in from a
    /// `postgres://` link. Nothing is stored — the record is a stub in the list
    /// until the user presses Save.
    @MainActor
    static func show(prefill: ParsedConnectionURL) {
        show()
        guard let manager = shared?.window?.contentViewController as? ConnectionsManagerVC else { return }
        manager.beginNewConnection(prefilled: config(from: prefill),
                                   passwordFromLink: prefill.passwordWasInURL)
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

    init() {
        let defaultRect = NSRect(x: 0, y: 0, width: 860, height: 560)
        // Standard (non-fullSizeContentView) title bar: content sits naturally
        // below the title bar, no overlap with the sidebar list, no scroll
        // view inset gymnastics for the right pane.
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connections"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = ConnectionsManagerVC()

        super.init(window: window)
        window.delegate = self

        if !window.setFrameUsingName(Self.frameAutosaveKey) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveKey)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }

    /// ⌘W is File > Close Tab, whose action only the content controller
    /// answers, so in this window it did nothing. Closing the window is what
    /// the key means for a window with no tabs in it.
    @MainActor
    @objc func menuCloseTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}
