import AppKit
import Combine

class MainWindowController: NSWindowController {

    /// This window's state: its tabs, its active tab, its connection and its
    /// results. Made here and handed down the controller tree, so no pane ever
    /// has to ask `view.window` which session it belongs to.
    let session: WindowSession

    let splitViewController: PharosSplitViewController
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var toolbarController: MainToolbarController?

    /// The frame of the last window built, so the next one cascades off it
    /// rather than landing exactly on top.
    private static var lastCascadePoint: NSPoint?

    /// Set once the user has answered the unsaved-work warning for this
    /// window, so a close made from that answer is not asked about again.
    private var isCloseConfirmed = false

    /// How many main windows have been built this run. It only numbers the AX
    /// identifiers, so it counts up and never down: two windows must never
    /// share `window.main.1`, even after the first is closed.
    private static var windowCount = 0

    /// `initialConnectionId` seeds the new window's connection BEFORE its
    /// content controller loads. That controller calls `ensureTab()` as soon
    /// as its view appears, and the tab it makes takes its connection and
    /// default schema from the session — so a value set afterwards would
    /// arrive one tab too late.
    init(initialConnectionId: String? = nil) {
        let session = AppStateManager.shared.makeSession()
        session.activeConnectionId = initialConnectionId
        self.session = session
        self.splitViewController = PharosSplitViewController(session: session)

        let defaultContentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: defaultContentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pharos"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 800, height: 400)
        // Native window tabs. The identifier is what lets two main windows form
        // one tab group; AppKit then supplies Show Tab Bar, Show All Tabs, Move
        // Tab to New Window and Merge All Windows by itself.
        //
        // `.automatic`, not `.preferred`: `.preferred` makes every new window
        // open as a TAB whatever the user has chosen under Desktop & Dock ▸
        // "Prefer tabs when opening documents" — verified live, with that
        // setting on "In Full Screen Only", ⌘N still produced one window with
        // two tabs. `.automatic` follows the setting, so ⌘N gives a window to
        // someone who wants windows and a tab to someone who wants tabs, and
        // Merge All Windows is there either way.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "PharosMain"
        // Opts the window into full screen. AppKit then adds View > Enter Full
        // Screen itself — there is deliberately no menu item of our own.
        window.collectionBehavior = [.fullScreenPrimary]

        // Restoration is OURS, not AppKit's. `session_tabs` records every open
        // window with its frame, its tabs and its active tab, and the delegate
        // replays that list in order at launch. Leaving `isRestorable` on would
        // put a second, unordered path beside it that can duplicate windows.
        window.isRestorable = false

        Self.windowCount += 1
        // Numbered, because `scripts/ax-walk.swift` and the navigation baseline
        // find a window by this identifier: with N windows, one shared name
        // names the wrong one.
        window.setAccessibilityIdentifier("window.main.\(Self.windowCount)")

        super.init(window: window)

        window.delegate = self
        window.contentViewController = splitViewController

        placeWindow(defaultContentRect: defaultContentRect)

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWindowFrame),
            name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWindowFrame),
            name: NSWindow.didMoveNotification, object: window)

        let toolbarController = MainToolbarController(
            session: session,
            splitVC: splitViewController
        )
        toolbarController.install(on: window)
        self.toolbarController = toolbarController
    }

    /// Put the window somewhere sensible: the frame a caller restored from the
    /// store, else cascaded off the last window built, else centred.
    ///
    /// The frame is NOT read from `setFrameUsingName` any more — one autosave
    /// key cannot serve N windows. Each window's frame travels in its own
    /// `SessionWindow` row instead, and `AppDelegate.openMainWindow(frame:)`
    /// applies it right after this.
    private func placeWindow(defaultContentRect: NSRect) {
        guard let window = window else { return }
        window.setFrame(defaultContentRect, display: false)
        if let previous = Self.lastCascadePoint {
            // `cascadeTopLeft(from:)` puts this window's top-left AT the point
            // and RETURNS the point for the next one. Storing the return, not
            // the window's own corner, is what makes the third window step
            // again instead of landing on the second.
            Self.lastCascadePoint = window.cascadeTopLeft(from: previous)
        } else {
            window.center()
            // Zero moves nothing; it only asks where the next window goes.
            Self.lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
        saveWindowFrame()
    }

    /// Apply a stored frame, ignoring one that no longer makes sense — 0×0, or
    /// on a display that is no longer attached — which would otherwise hand the
    /// first layout pass an invalid context.
    func applyStoredFrame(_ frame: NSRect) {
        guard let window = window, Self.isFrameValid(frame, minSize: window.minSize) else { return }
        window.setFrame(frame, display: false)
        Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        saveWindowFrame()
    }

    static func isFrameValid(_ frame: NSRect, minSize: NSSize) -> Bool {
        guard frame.size.width.isFinite, frame.size.height.isFinite else { return false }
        guard frame.size.width >= minSize.width, frame.size.height >= minSize.height else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    // Manual — setFrameAutosaveName doesn't reliably write on resize under
    // macOS 26, and with more than one window there is no single key to write
    // to. The frame goes on the session and is stored with the window's row.
    @objc private func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        session.frameDescription = SessionWindow.description(of: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Connection Actions (called from menu bar)

    @objc func showConnectionsManager() {
        ConnectionsManagerWindowController.show()
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    /// Plan §5.2 L: a window close takes every one of its tabs with it, so it
    /// asks about all of them at once, in the same words a single tab close
    /// uses.
    ///
    /// The answer arrives later, so the close is refused now and made again
    /// from the completion. `window.close()` does not consult this delegate,
    /// but `performClose(_:)` does, and `isCloseConfirmed` is what stops the
    /// second pass asking the same question again.
    ///
    /// Quitting does NOT come through here — AppKit closes the windows itself
    /// once `applicationShouldTerminate` has answered, and that method does its
    /// own asking. The `isTerminating` guard is what keeps the two from
    /// stacking a second dialog on top of the quit's.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isCloseConfirmed || stateManager.isTerminating { return true }
        let contentVC = splitViewController.contentVC
        let unsaved = contentVC.unsavedWorkTabs
        guard !unsaved.isEmpty else { return true }
        contentVC.confirmClosing(unsaved) { [weak self] proceed in
            guard let self, proceed else { return }
            self.isCloseConfirmed = true
            self.window?.close()
        }
        return false
    }

    /// A closed window takes its session with it: its tabs are gone, and the
    /// queries it started are cancelled — a query belongs to the window that
    /// started it.
    ///
    /// The editor text of its workspace-bound tabs is flushed FIRST, while the
    /// tabs still exist; after `retire` there is nothing left to read.
    func windowWillClose(_ notification: Notification) {
        stateManager.snapshotWorkspaces()
        stateManager.retire(session)
        (NSApp.delegate as? AppDelegate)?.forget(self)
    }
}
