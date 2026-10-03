// Standalone test for CardRunAvailability: when a card's Run button is greyed
// out, and what it says. Compiled by scripts/test-card-run-availability.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func runTests() {
    let r = CardRunAvailability.reason

    expect(r("c1", "Prod", .connected) == nil, "connected: Run is available")

    let none = r(nil, nil, nil)
    expect(none?.contains("no database connection") == true, "no connection: says the tab has none", "got \(String(describing: none))")
    let gone = r("c1", nil, .connected)
    expect(gone == none, "a connection that no longer exists reads as no connection", "got \(String(describing: gone))")

    let off = r("c1", "Prod", .disconnected)
    expect(off?.contains("Not connected to “Prod”") == true && off?.contains("Connect") == true,
           "disconnected: names the connection and says how to connect", "got \(String(describing: off))")
    expect(r("c1", "Prod", nil) == off, "never connected reads as disconnected")

    let busy = r("c1", "Prod", .connecting)
    expect(busy?.contains("Connecting to “Prod”") == true, "connecting: says it is connecting", "got \(String(describing: busy))")

    let failed = r("c1", "Prod", .error)
    expect(failed?.contains("Could not connect to “Prod”") == true, "error: says the connection failed", "got \(String(describing: failed))")

    if failures == 0 { print("\nAll card run availability tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
