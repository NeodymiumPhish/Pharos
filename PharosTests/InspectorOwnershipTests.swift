// Standalone test runner for InspectorOwnership — the rule that decides who
// may blank the SHARED Inspector pane.
// Compiled with the implementation by scripts/test-inspector-ownership.sh.
import Foundation

var failures = 0

func expect(_ actual: Bool, _ expected: Bool, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let every: [InspectorOwner] = [.none, .results, .schemaBrowser, .sqlView]

    // The bug this rule exists for. The schema browser owns the pane; running
    // a query rebuilds the grid, which clears its selection as a SIDE EFFECT
    // and asks to blank. It must be refused, or the table detail is destroyed.
    expect(InspectorOwnership.allowsWithdrawal(currentOwner: .schemaBrowser, writer: .results),
           false, "the results area cannot blank a schema-browser detail")

    // The behaviour that must survive the fix: deselecting in the grid, while
    // the grid's OWN row detail is on screen, still clears the pane.
    expect(InspectorOwnership.allowsWithdrawal(currentOwner: .results, writer: .results),
           true, "the results area may withdraw its own row detail")

    // Every writer owns its own content, and no writer owns another's.
    for owner in every where owner != .none {
        expect(InspectorOwnership.allowsWithdrawal(currentOwner: owner, writer: owner),
               true, "\(owner) may withdraw its own content")
        for writer in every where writer != owner {
            expect(InspectorOwnership.allowsWithdrawal(currentOwner: owner, writer: writer),
                   false, "\(writer) may not withdraw \(owner)'s content")
        }
    }

    // `.none` names no writer. It can neither withdraw nor be withdrawn from:
    // an unowned pane is already blank, so blanking it again is not a decision
    // this rule should hand back as "allowed".
    for writer in every {
        expect(InspectorOwnership.allowsWithdrawal(currentOwner: .none, writer: writer),
               false, "nothing can be withdrawn from an unowned pane (\(writer))")
    }
    for owner in every {
        expect(InspectorOwnership.allowsWithdrawal(currentOwner: owner, writer: .none),
               false, "`.none` is not a writer and may withdraw nothing (\(owner))")
    }

    if failures == 0 {
        print("\nAll InspectorOwnership tests passed.")
    } else {
        print("\n\(failures) test(s) failed.")
        exit(1)
    }
}
