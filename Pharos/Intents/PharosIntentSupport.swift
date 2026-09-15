import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Activity types

/// The `NSUserActivity` types Pharos donates. Each one is also listed in
/// `NSUserActivityTypes` in `Info.plist`; a type missing from that list is
/// silently dropped by the system.
///
/// The string is a literal, not built from the bundle identifier: a re-identified
/// test copy must still hand back an activity the shipped app would recognise,
/// and the value is stored inside donated activities that outlive the process.
enum PharosActivity {
    /// A query tab that is bound to a workspace-history record.
    /// `userInfo["workspaceId"]` names the workspace.
    static let workspace = "com.pharos.client.workspace"
    /// The `userInfo` key carrying the workspace id.
    static let workspaceIdKey = "workspaceId"
}

// MARK: - Errors

/// Failures an intent reports back to Shortcuts. Each case carries the text the
/// user sees, so the automation says what went wrong rather than "the action
/// failed".
enum PharosIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noMainWindow
    case unknownConnection
    case connectionFailed(String)
    case unknownSavedQuery
    case noConnectionForQuery
    case queryTimedOut
    case noResult
    case columnsUnavailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noMainWindow:
            return "Pharos could not open its main window."
        case .unknownConnection:
            return "That connection is no longer saved in Pharos."
        case .connectionFailed(let reason):
            return "Pharos could not connect: \(reason)"
        case .unknownSavedQuery:
            return "That saved query is no longer in Pharos."
        case .noConnectionForQuery:
            return "This saved query has no connection, so Pharos cannot run it."
        case .queryTimedOut:
            return "The query did not finish in time."
        case .noResult:
            return "The query returned no result to hand back."
        case .columnsUnavailable(let reason):
            return "Pharos could not read the table's columns: \(reason)"
        }
    }
}

// MARK: - Bridge into the running app

/// The single place an intent touches the app's window and controllers.
///
/// Every intent that shows something runs with `openAppWhenRun = true`, so the
/// app is already launching when `perform()` starts — but the window may still
/// be closed (Pharos does not quit with its window), which is why each entry
/// point goes through `showMainWindow()`.
enum PharosIntentBridge {

    /// Bring the app forward with its main window on screen.
    @MainActor
    @discardableResult
    static func showMainWindow() throws -> MainWindowController {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw PharosIntentError.noMainWindow
        }
        let controller = delegate.showMainWindow()
        NSApp.activate()
        return controller
    }

    /// The live `ContentViewController`, the same way `AppStateManager.openTextFile`
    /// reaches it: down the split view's children.
    @MainActor
    static func contentViewController() throws -> ContentViewController {
        let controller = try showMainWindow()
        guard let split = controller.contentViewController as? PharosSplitViewController else {
            throw PharosIntentError.noMainWindow
        }
        for item in split.splitViewItems {
            if let content = item.viewController as? ContentViewController { return content }
        }
        throw PharosIntentError.noMainWindow
    }

    /// Poll `condition` on the main actor until it holds or `timeout` elapses.
    /// Returns whether it held. Used instead of a Combine sink because an intent
    /// has no lifetime to store a subscription in.
    static func wait(upTo timeout: TimeInterval,
                     every interval: TimeInterval = 0.2,
                     until condition: @MainActor @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return await MainActor.run(body: condition)
    }

    /// Connect `connectionId` and wait for the attempt to settle.
    /// Throws when it ends in an error or never settles.
    @MainActor
    static func ensureConnected(_ connectionId: String) async throws {
        let state = AppStateManager.shared
        guard state.connections.contains(where: { $0.id == connectionId }) else {
            throw PharosIntentError.unknownConnection
        }
        if state.status(for: connectionId) == .connected { return }
        if state.status(for: connectionId) != .connecting {
            state.connect(id: connectionId)
        }
        let settled = await PharosIntentBridge.wait(upTo: 30) {
            AppStateManager.shared.status(for: connectionId) != .connecting
        }
        guard settled else { throw PharosIntentError.connectionFailed("the attempt timed out") }
        guard state.status(for: connectionId) == .connected else {
            throw PharosIntentError.connectionFailed("the database refused the connection")
        }
    }
}

// MARK: - CSV for an intent's return value

/// The `IntentFile` wrapper. The text itself, and the filename, are built in
/// `IntentResultCSV` (`IntentResultCSV.swift`), which imports nothing from
/// AppIntents so `scripts/test-intent-csv.sh` can compile it on its own.
extension IntentResultCSV {

    /// The CSV as an `IntentFile`, named after the query.
    static func file(from result: QueryResult, named name: String) -> IntentFile {
        let text = csv(from: result)
        var file = IntentFile(
            data: Data(text.utf8),
            filename: "\(sanitizedFilename(name)).csv",
            type: .commaSeparatedText
        )
        // The shortcut may well save or mail this after the action returns.
        file.removedOnCompletion = false
        return file
    }
}
