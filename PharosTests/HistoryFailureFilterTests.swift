// Standalone test runner for HistoryFailureFilter and ConnectionLossClassifier
// — the two pure judgements about a failed query. Compiled by
// scripts/test-query-failure-classification.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func testRecorded() {
    // Server answers: every one of these belongs in history.
    for message in [
        "ERROR: relation \"userz\" does not exist",
        "ERROR: syntax error at or near \"SELCT\"",
        "ERROR: permission denied for table accounts",
        "ERROR: division by zero",
        "canceling statement due to statement timeout",
        "ERROR: duplicate key value violates unique constraint \"users_pkey\"",
    ] {
        expectEqual(HistoryFailureFilter.shouldRecord(message), true, "recorded: \(message.prefix(40))")
    }
    expectEqual(HistoryFailureFilter.shouldRecord(""), true, "an empty message is recorded, not dropped")
    expectEqual(HistoryFailureFilter.shouldRecord("   "), true, "a blank message is recorded")
}

private func testSkipped() {
    for message in [
        "Not connected to: c1",
        "Connect to a database to run a query.",
        "SSH tunnel closed: ssh: connect to host db.example.invalid port 22: Operation timed out",
        "Unresolved variables: target_ip, since",
        "No SQL to run",
    ] {
        expectEqual(HistoryFailureFilter.shouldRecord(message), false, "skipped: \(message.prefix(40))")
    }
    // Case and surrounding context must not matter: the message reaches the
    // filter wrapped in whatever the catch site added.
    expectEqual(HistoryFailureFilter.shouldRecord("Query failed: NOT CONNECTED TO: c1"), false,
                "matching ignores case and surrounding text")
}

private func testConnectionLoss() {
    for message in [
        "Not connected to: c1",
        "SSH tunnel closed: ssh exited",
        "error returned from database: connection closed",
        "Connection reset by peer",
        "io error: Broken pipe",
        "PoolTimedOut",
        "server closed the connection unexpectedly",
        "FATAL: terminating connection due to administrator command",
    ] {
        expectEqual(ConnectionLossClassifier.isConnectionLoss(message), true, "loss: \(message.prefix(40))")
    }
    // The ones that must NOT drop the pool. A statement timeout is the single
    // most common failure in this app, and treating it as a dead connection
    // would disconnect the user every time a query ran long.
    for message in [
        "ERROR: canceling statement due to statement timeout",
        "ERROR: canceling statement due to user request",
        "Query was cancelled",
        "ERROR: relation \"users\" does not exist",
        "ERROR: syntax error at or near \"FROM\"",
        "ERROR: permission denied for table accounts",
        "",
    ] {
        expectEqual(ConnectionLossClassifier.isConnectionLoss(message), false, "not a loss: \(message.prefix(40))")
    }
}

func runTests() {
    testRecorded()
    testSkipped()
    testConnectionLoss()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
