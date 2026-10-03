// Standalone test for TabContextState (what the tab's context row says about
// its connection) and the transaction chip titles. Compiled by
// scripts/test-tab-context-state.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func testState() {
    let none = TabContextState(connectionName: nil, status: nil, failureReason: nil)
    expect(none == .chooseConnection, "no connection: choose one")
    expect(none.text == "Choose a database for this tab." && none.buttonTitle == nil, "no connection: says so, no button")

    let off = TabContextState(connectionName: "Coda", status: .disconnected, failureReason: nil)
    expect(off == .notConnected && off.buttonTitle == "Connect" && off.text == "Not connected",
           "disconnected: Connect button", "\(off)")
    expect(TabContextState(connectionName: "Coda", status: nil, failureReason: nil) == .notConnected,
           "never connected reads as not connected")

    let busy = TabContextState(connectionName: "Coda", status: .connecting, failureReason: nil)
    expect(busy == .connecting && busy.showsSpinner && busy.buttonTitle == nil && busy.text == "Connecting…",
           "connecting: spinner, no button")

    let on = TabContextState(connectionName: "Coda", status: .connected, failureReason: nil)
    expect(on == .connected && on.text == "Connected" && on.buttonTitle == nil && !on.showsSpinner, "connected: text only")

    let failed = TabContextState(connectionName: "Coda", status: .error, failureReason: "password authentication failed")
    expect(failed == .failed(reason: "password authentication failed") && failed.buttonTitle == "Try Again",
           "error: Try Again", "\(failed)")
    expect(failed.text == "Could not connect" && failed.toolTip == "password authentication failed",
           "error: the reason is in the tooltip")
}

private func testChipTitles() {
    expect(TabSessionBannerState.transaction(elapsed: 134, idleRemaining: 400).chipTitle == "Transaction open · 2 min",
           "chip: open transaction with its age", TabSessionBannerState.transaction(elapsed: 134, idleRemaining: 400).chipTitle)
    expect(TabSessionBannerState.transaction(elapsed: 12, idleRemaining: nil).chipTitle == "Transaction open · 12 s", "chip: seconds")
    expect(TabSessionBannerState.failed.chipTitle == "Transaction failed", "chip: failed")
    expect(TabSessionBannerState.reset(reason: "x").chipTitle == "Connection reset", "chip: reset")
}

func runTests() {
    testState()
    testChipTitles()
    if failures == 0 { print("\nAll tab context state tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
