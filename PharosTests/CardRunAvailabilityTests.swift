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
    let r = { (id: String?, name: String?, status: ConnectionStatus?) in
        CardRunAvailability.reason(connectionId: id, connectionName: name, status: status)
    }

    expect(r("c1", "Prod", .connected) == nil, "connected: Run is available")

    let none = r(nil, nil, nil)
    expect(none?.contains("no database connection") == true, "no connection: says the tab has none", "got \(String(describing: none))")
    for status: ConnectionStatus? in [nil, .disconnected, .error] {
        let r = CardRunAvailability.reason(connectionId: "c", connectionName: "Coda", status: status) ?? ""
        expect(!r.contains("toolbar"), "no reason points at the removed toolbar menu (\(String(describing: status)))")
        expect(r.contains("above the cards") && r.contains("File ▸ Connect"), "the reason names the context row and File ▸ Connect")
    }
    expect(none?.contains("Connection pop-up above the cards") == true, "no connection: names the pop-up")
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

    // A DuckDB failure the context row has its own button for: the help
    // names THAT button, the one TabContextState shows for the same error.
    let kinds: [(String, String, Bool, Bool, Bool)] = [
        ("missing", "x \(DuckDBOpenError.missingMarker)", true, false, false),
        ("locked", "x \(DuckDBOpenError.lockedMarker)", false, true, false),
        ("plain", "connection refused", false, false, false),
    ]
    for (label, error, missing, locked, tooNew) in kinds {
        let help = CardRunAvailability.reason(connectionId: "c1", connectionName: "Sales", status: .error, error: error) ?? ""
        let state = TabContextState(connectionName: "Sales", status: .error, failureReason: nil,
                                    missingFile: missing, inUse: locked, tooNew: tooNew)
        let button = state.buttonTitle ?? "<none>"
        expect(help.contains(button), "\(label): the help names the context row's \(button) button", "got \(help)")
    }
    let lost = CardRunAvailability.reason(connectionId: "c1", connectionName: "Sales", status: .error,
                                          error: "x \(DuckDBOpenError.missingMarker)") ?? ""
    expect(!lost.contains("Try Again"), "missing file: no Try Again, which the row does not show", "got \(lost)")
    let newer = CardRunAvailability.reason(connectionId: "c1", connectionName: "Sales", status: .error,
                                           error: "x \(DuckDBOpenError.tooNewMarker)") ?? ""
    expect(newer.contains("newer DuckDB") && !newer.contains("Click"),
           "too new: says why, and names no button (the row has none)", "got \(newer)")

    if failures == 0 { print("\nAll card run availability tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
