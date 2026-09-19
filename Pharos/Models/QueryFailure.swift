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

    /// The pre-substitution `{{var}}` form of `sql`, when the run had one.
    ///
    /// Carried so a recorded failure holds the same editor text a recorded
    /// SUCCESS does — the two rows sit in the same list, and one of them
    /// answering "which statement was that?" while the other cannot would be
    /// the difference the user noticed.
    var rawSQL: String? = nil

    /// The editor line range the failed statement came from, 1-based and
    /// inclusive. Nil when the run came from no editor segment — a browse
    /// action, a whole-editor run, a drill.
    ///
    /// Only the run itself knows this, which is half the reason the Query
    /// History record is driven from Swift rather than from the core's own
    /// failure site. Set it at every site that HAS a range; a nil here is
    /// recorded as "no range", exactly as it is for a successful run.
    var lineRange: ClosedRange<Int>? = nil

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
        parts.append(timestamp.formatted(Self.timeStyle))
        return parts.joined(separator: " · ")
    }

    /// `.standard` (h:mm:ss) is the closest `Date.FormatStyle` match to the
    /// legacy `DateFormatter` `.medium` time style this replaces — both include
    /// seconds, neither shows a date or time zone.
    private static let timeStyle = Date.FormatStyle(time: .standard, locale: .autoupdatingCurrent)
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

    /// "2 of 3". Static and count-taking, because the sheet shows an entry list
    /// rather than a log, and one format string in two places drifts.
    static func counterText(index: Int, count: Int) -> String { "\(index + 1) of \(count)" }

    /// Which entry the sheet shows after the one at `removedIndex` leaves the
    /// log. Nil means the log is empty and the sheet must close.
    static func indexAfterRemoval(removedIndex: Int, remainingCount: Int) -> Int? {
        guard remainingCount > 0 else { return nil }
        return min(max(removedIndex, 0), remainingCount - 1)
    }
}
