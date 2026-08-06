// Standalone test runner for QueryFailure / QueryFailureLog. Not part of the app
// target — compiled with the implementation by scripts/test-query-failure-log.sh.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func failure(_ id: String, kind: QueryFailure.Kind = .error, message: String = "boom") -> QueryFailure {
    QueryFailure(
        id: id, sql: "SELECT 1", message: message, kind: kind,
        tabId: "tab-1", tabName: "Query 1", connectionName: "localhost",
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

func runTests() {
    // MARK: append order and cap

    var log = QueryFailureLog()
    log.append(failure("a"))
    log.append(failure("b"))
    expectString(log.entries.first?.id ?? "", "b", "append puts the newest entry first")
    expectInt(log.count, 2, "the log counts both entries")

    var big = QueryFailureLog()
    for i in 0..<(QueryFailureLog.capacity + 5) { big.append(failure("f\(i)")) }
    expectInt(big.count, QueryFailureLog.capacity, "the log never grows past its capacity")
    expectString(big.entries.first?.id ?? "", "f\(QueryFailureLog.capacity + 4)",
                 "the newest entry survives the cap")
    expectTrue(big.index(of: "f0") == nil, "the oldest entry leaves when the cap is reached")

    // MARK: read state

    let empty = QueryFailureLog()
    expectTrue(empty.newestUnreadIndex == nil, "newestUnreadIndex on an empty log gives nil")

    var read = QueryFailureLog()
    read.append(failure("a"))
    read.append(failure("b"))
    expectInt(read.unreadCount, 2, "a new entry starts unread")
    read.markRead(id: "b")
    expectInt(read.unreadCount, 1, "markRead lowers the unread count")
    expectInt(read.newestUnreadIndex ?? -1, 1, "newestUnreadIndex points at the newest unread entry")
    read.markRead(id: "a")
    expectInt(read.newestUnreadIndex ?? -1, 0, "with every entry read the index falls back to 0")

    read.markRead(id: "does-not-exist")
    expectInt(read.unreadCount, 0, "markRead with an unknown id leaves unreadCount unchanged")

    // MARK: remove

    var rm = QueryFailureLog()
    rm.append(failure("a"))
    rm.append(failure("b"))
    rm.append(failure("c"))       // order is now c, b, a
    rm.remove(id: "b")
    expectInt(rm.count, 2, "remove takes one entry out")
    expectString(rm.entries.map { $0.id }.joined(separator: ","), "c,a",
                 "remove leaves the other entries in order")
    rm.markRead(id: "c")
    expectInt(rm.unreadCount, 1, "one unread entry is left")
    rm.remove(id: "a")
    expectInt(rm.unreadCount, 0, "removing an unread entry lowers the unread count")

    rm.remove(id: "does-not-exist")
    expectInt(rm.count, 1, "remove with an unknown id leaves the count unchanged")

    rm.removeAll()
    expectInt(rm.count, 0, "removeAll empties the log")

    // MARK: index after a removal — the rule the sheet follows

    expectInt(QueryFailureLog.indexAfterRemoval(removedIndex: 1, remainingCount: 2) ?? -1, 1,
              "removing a middle entry shows the entry that takes its index")
    expectInt(QueryFailureLog.indexAfterRemoval(removedIndex: 1, remainingCount: 1) ?? -1, 0,
              "removing the last entry shows the entry before it")
    expectTrue(QueryFailureLog.indexAfterRemoval(removedIndex: 0, remainingCount: 0) == nil,
               "removing the only entry gives no index, so the sheet closes")

    // MARK: counter and sub-header

    expectString(QueryFailureLog.counterText(index: 1, count: read.count), "2 of 2",
                 "the counter counts from 1")
    expectTrue(failure("a").subheader.hasPrefix("Query 1 · localhost · "),
               "the sub-header holds the tab name, then the connection, then the time")
    expectString(failure("a", kind: .cancelled).title, "Query Cancelled",
                 "a cancellation gets its own title")
    expectString(failure("a").title, "Query Failed", "an error gets the failure title")

    // MARK: location reads the message, not the sql

    let withPosition = failure("a", message: "syntax error at character 12")
    expectInt(withPosition.location?.charPosition ?? -1, 12,
              "a message with a position gives a location at that character")
    let withoutPosition = failure("a", message: "connection refused")
    expectTrue(withoutPosition.location == nil,
               "a message with no position gives a nil location")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
