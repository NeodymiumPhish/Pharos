import Foundation

/// One failed or cancelled query run, kept on its editor tab so the user can
/// read it again after the sheet closes.
struct QueryFailure: Identifiable, Equatable {

    enum Kind: Equatable { case error, cancelled }

    /// The `queryId` of the run that failed. One per run, so it is a stable id.
    let id: String

    /// The substituted SQL that actually ran. The error position counts into
    /// this text, not into the editor's token form.
    let sql: String

    let message: String
    let kind: Kind
    let tabId: String
    let tabName: String
    let connectionName: String?
    let timestamp: Date

    /// False until the sheet shows this entry. Drives the pulse on the tab button.
    var isRead: Bool = false

    /// Where the message points inside `sql`, when it points anywhere.
    ///
    /// Recomputed on every read — cache the result before reading it inside a
    /// redraw or a scroll loop.
    var location: SQLErrorLocation? { SQLErrorLocation.parse(from: message) }

    var title: String {
        switch kind {
        case .error: return "Query Failed"
        case .cancelled: return "Query Cancelled"
        }
    }

    var symbolName: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    /// "Query 1 · localhost · 14:32:07". The sheet sub-header and the banner
    /// both use this, so the two always agree.
    var subheader: String {
        var parts = [tabName]
        if let connectionName, !connectionName.isEmpty { parts.append(connectionName) }
        parts.append(Self.timeFormatter.string(from: timestamp))
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Newest-first failure record for one editor tab.
struct QueryFailureLog: Equatable {

    /// A long session that repeats one failure must not grow without limit.
    static let capacity = 20

    private(set) var entries: [QueryFailure] = []

    var count: Int { entries.count }

    /// Entries the sheet has never shown. Drives the pulse on the tab button.
    var unreadCount: Int { entries.reduce(0) { $0 + ($1.isRead ? 0 : 1) } }

    /// Index the error button opens at: the newest unread entry, or the newest
    /// entry when the user has read them all. Nil when the log is empty, so a
    /// caller cannot use it as an index into nothing — the same convention as
    /// `indexAfterRemoval`.
    var newestUnreadIndex: Int? {
        guard !entries.isEmpty else { return nil }
        return entries.firstIndex { !$0.isRead } ?? 0
    }

    mutating func append(_ failure: QueryFailure) {
        entries.insert(failure, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    mutating func markRead(id: String) {
        guard let i = index(of: id) else { return }
        entries[i].isRead = true
    }

    mutating func remove(id: String) {
        guard let i = index(of: id) else { return }
        entries.remove(at: i)
    }

    mutating func removeAll() { entries.removeAll() }

    func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }

    func counterText(index: Int) -> String { "\(index + 1) of \(entries.count)" }

    /// Which entry the sheet shows after the one at `removedIndex` leaves the
    /// log. Nil means the log is empty and the sheet must close.
    static func indexAfterRemoval(removedIndex: Int, remainingCount: Int) -> Int? {
        guard remainingCount > 0 else { return nil }
        return min(max(removedIndex, 0), remainingCount - 1)
    }
}
