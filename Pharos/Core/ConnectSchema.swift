import Foundation

/// Which schema a window and its active tab land on when a connection opens.
///
/// Pure, so `scripts/test-connect-schema.sh` can pin the order without the
/// FFI behind `AppStateManager.connect`.
enum ConnectSchema {
    /// - Parameters:
    ///   - tabSchema: the active tab's own schema, when the tab names THIS
    ///     connection — chosen by the user, or restored from the last run.
    ///   - configured: the connection's default schema from its record, nil
    ///     or empty meaning "none configured".
    ///   - windowRemembered: what this window was last using for the
    ///     connection.
    ///
    /// The tab's own schema wins. A tab restored at launch shows the schema it
    /// was linked to last time, and connecting must keep that link; the
    /// connection's configured default is for a tab that has not chosen —
    /// new tabs get it in `WindowSession.createTab`, and the toolbar pick
    /// applies it when a tab CHANGES connection (`useConnection`). Then the
    /// window's own memory of the connection, then `public`.
    static func resolve(tabSchema: String?, configured: String?, windowRemembered: String?) -> String {
        let configuredOrNil = configured.flatMap { $0.isEmpty ? nil : $0 }
        return tabSchema ?? configuredOrNil ?? windowRemembered ?? "public"
    }
}
