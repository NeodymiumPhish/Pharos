// Standalone test runner for LaunchConnectPolicy — which connections Pharos
// opens for itself at launch, and in what order. Compiled by
// scripts/test-launch-connect-policy.sh. No launch, no database, no window.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private typealias Candidate = LaunchConnectPolicy.Candidate

private func ids(_ list: [Candidate]) -> [String] { list.map(\.id) }

private func testOnlyTheFlaggedOnes() {
    let all = [
        Candidate(id: "a", name: "A", connectOnLaunch: true),
        Candidate(id: "b", name: "B", connectOnLaunch: false),
        Candidate(id: "c", name: "C", connectOnLaunch: true),
    ]
    expectEqual(ids(LaunchConnectPolicy.connectionsToOpen(all)), ["a", "c"],
                "only the flagged connections are opened")
    expectEqual(LaunchConnectPolicy.connectionsToOpen([]), [], "no connections, nothing to open")
    expectEqual(ids(LaunchConnectPolicy.connectionsToOpen([
        Candidate(id: "a", name: "A", connectOnLaunch: false),
    ])), [], "nothing flagged, nothing opened")
}

/// The case that would otherwise show a second connect attempt on a
/// connection the session restore already opened.
private func testAlreadyConnectedIsSkipped() {
    let all = [
        Candidate(id: "a", name: "A", connectOnLaunch: true, isAlreadyConnected: true),
        Candidate(id: "b", name: "B", connectOnLaunch: true, isAlreadyConnected: false),
    ]
    expectEqual(ids(LaunchConnectPolicy.connectionsToOpen(all)), ["b"],
                "a connection the restore already opened is left alone")
}

private func testGatedConnectionsGoLast() {
    let all = [
        Candidate(id: "gated1", name: "G1", connectOnLaunch: true, requiresAuthentication: true),
        Candidate(id: "plain1", name: "P1", connectOnLaunch: true),
        Candidate(id: "gated2", name: "G2", connectOnLaunch: true, requiresAuthentication: true),
        Candidate(id: "plain2", name: "P2", connectOnLaunch: true),
    ]
    expectEqual(ids(LaunchConnectPolicy.connectionsToOpen(all)),
                ["plain1", "plain2", "gated1", "gated2"],
                "the ones that will ask for Touch ID go last, and each group keeps its order")
}

private func testOrderIsOtherwiseThecallersOrder() {
    let all = [
        Candidate(id: "z", name: "Z", connectOnLaunch: true),
        Candidate(id: "a", name: "A", connectOnLaunch: true),
        Candidate(id: "m", name: "M", connectOnLaunch: true),
    ]
    expectEqual(ids(LaunchConnectPolicy.connectionsToOpen(all)), ["z", "a", "m"],
                "with no gate, the caller's own order is kept — it is not re-sorted")
}

private func testSerialPrompts() {
    let plain = [Candidate(id: "a", name: "A", connectOnLaunch: true)]
    expectEqual(LaunchConnectPolicy.needsSerialPrompts(plain), false,
                "nothing asks, so they need not be opened one at a time")
    let gated = [
        Candidate(id: "a", name: "A", connectOnLaunch: true),
        Candidate(id: "b", name: "B", connectOnLaunch: true, requiresAuthentication: true),
    ]
    expectEqual(LaunchConnectPolicy.needsSerialPrompts(gated), true,
                "one gated connection is enough to make the whole run serial")
    expectEqual(LaunchConnectPolicy.needsSerialPrompts([]), false, "nothing to open asks nothing")
}

func runTests() {
    testOnlyTheFlaggedOnes()
    testAlreadyConnectedIsSkipped()
    testGatedConnectionsGoLast()
    testOrderIsOtherwiseThecallersOrder()
    testSerialPrompts()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
