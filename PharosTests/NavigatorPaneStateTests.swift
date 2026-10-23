// Standalone tests for NavigatorPaneState: what the Database Navigator's pane
// shows in place of its tree. Compiled by scripts/test-navigator-pane-state.sh.
import Foundation

private var failures = 0

private func expect(_ actual: NavigatorPaneState, _ expected: NavigatorPaneState, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let r = NavigatorPaneState.resolve
    expect(r(false, .pending, nil), .noConnection, "no connection wins over any read")
    expect(r(true, .pending, nil), .reading("Reading the schemas…"), "the schema list is being read")
    expect(r(true, .pending, ("public", .pending)), .reading("Reading the schemas…"),
           "a pin set before the list arrives still waits for the list")
    expect(r(true, .failed("timeout"), nil),
           .failed(title: "Couldn’t Read the Schemas", message: "timeout"), "the schema list failed")
    expect(r(true, .loaded, ("public", .pending)), .reading("Reading the tables in public…"),
           "the pinned schema's tables are being read")
    expect(r(true, .loaded, ("public", .failed("permission denied"))),
           .failed(title: "Couldn’t Read the Tables in public", message: "permission denied"),
           "the pinned schema's tables failed")
    expect(r(true, .loaded, ("public", .loaded)), .tree, "the pinned schema is here: the tree")
    expect(r(true, .loaded, nil), .tree, "every schema listed: each shows its own loading row")
    if failures > 0 {
        print("\(failures) FAILED")
        exit(1)
    }
    print("All navigator pane state tests passed.")
}
