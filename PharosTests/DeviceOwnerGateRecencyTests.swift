// Standalone test runner for DeviceOwnerGateRecency — how long one passed
// Touch ID gate counts for. Compiled by
// scripts/test-device-owner-gate-recency.sh.
//
// This decides when the app does NOT ask the user to prove who they are, so
// every boundary is pinned here rather than left to a literal at a call site.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let now = Date(timeIntervalSince1970: 1_000_000)

private func testFreshness() {
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now, now: now), true,
                "a gate that just passed counts")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(-1), now: now), true,
                "a second ago counts")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(-119), now: now), true,
                "just inside the window counts")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(-120), now: now), false,
                "the window itself does NOT count — the boundary is exclusive")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(-121), now: now), false,
                "past the window does not count")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(-3600), now: now), false,
                "an hour ago certainly does not count")
}

/// The clock can move BACKWARDS — NTP, a timezone tool, the user. A stored
/// future timestamp must not hold the gate open while it catches up.
private func testAFuturePassDoesNotCount() {
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(1), now: now), false,
                "a pass in the future does not count")
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now.addingTimeInterval(86_400), now: now), false,
                "a pass a day in the future does not count either")
}

private func testTheWindowIsTheDocumentedOne() {
    expectEqual(DeviceOwnerGateRecency.window, 120,
                "the window is two minutes: one piece of work, not an unattended Mac")
    // An explicit window overrides, so a caller that wants none can say so.
    expectEqual(DeviceOwnerGateRecency.isFresh(passedAt: now, now: now, window: 0), false,
                "a zero window never counts, even for a pass this instant")
}

func runTests() {
    testFreshness()
    testAFuturePassDoesNotCount()
    testTheWindowIsTheDocumentedOne()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
