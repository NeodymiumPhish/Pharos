import CoreGraphics
import Foundation

// The Rust mirrors (`pharos-core/src/models/session.rs`) use
// `#[serde(rename_all = "camelCase")]`, and `JSONDecoder.pharos` applies NO key
// strategy, so these property names ARE the JSON keys. Every field must exist on
// both sides: `load_session` re-serializes the Rust struct, so a Swift-only
// field would make the synthesized decode throw.

/// One editor tab as it was left at the end of the last run.
struct SessionTab: Codable, Equatable {
    /// Position in the tab bar, 0-based.
    var tabIndex: Int
    /// Set only for a tab that has run a query. The workspace row holds the
    /// authoritative editor text, variables and cursor for such a tab; the
    /// copies below are the fallback for a workspace that no longer exists.
    var workspaceId: String?
    var name: String
    /// False when `name` is the generated "Query <n>".
    var nameIsCustom: Bool
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int
    /// `[QueryVariable]` encoded as JSON, exactly as a workspace snapshot stores it.
    var variablesJson: String?
    var isActive: Bool
}

/// One main window as it was left at the end of the last run: where it was on
/// screen, and the tabs it held.
struct SessionWindow: Codable, Equatable {
    /// The window's grouping key in the store. It is a fresh UUID each run —
    /// nothing outside the table refers to it — so it only has to hold the
    /// rows of one window together.
    var windowId: String
    /// Position in the window order, 0-based. Window 0 is the one the app
    /// shows first; the rest are opened after it, in this order.
    var windowIndex: Int
    /// `"x,y,w,h"` in screen coordinates, or nil for a window that never
    /// recorded one. One `saveFrame(usingName:)` key cannot serve N windows,
    /// so each window's frame travels with its row.
    var frame: String?
    var tabs: [SessionTab] = []

    /// The stored `"x,y,w,h"` as a rect. Nil for anything that does not read
    /// as four finite numbers — the store is a file, so a damaged value must
    /// degrade to "no stored frame", never to a window at 0×0.
    static func rect(from description: String) -> NSRect? {
        let values = description.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// The inverse of `rect(from:)`.
    static func description(of rect: NSRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.size.width),\(rect.size.height)"
    }
}

/// Every open window, in window order.
struct Session: Codable, Equatable {
    var windows: [SessionWindow] = []
}
