// Standalone test runner for RunControlState — what the toolbar's Run | Cancel
// control shows per run state. Compiled by scripts/test-run-control-state.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // Idle.
    var s = RunControlState(canRun: true, runningCount: 0, pulse: 0.7)
    expectEqual(s.runEnabled, true, "idle: Run follows canRun")
    expectEqual(s.cancelEnabled, false, "idle: Cancel is disabled")
    expectEqual(s.tintStep, nil, "idle: the Cancel glyph is the plain template, whatever the pulse")
    expectEqual(s.cancelAction, .none, "idle: Cancel does nothing")
    expectEqual(s.cancelToolTip, "Cancel Query (⌘.)", "idle: tooltip")
    expectEqual(s.cancelAccessibilityLabel, "Cancel Query", "idle: AX label")

    s = RunControlState(canRun: false, runningCount: 0, pulse: 1)
    expectEqual(s.runEnabled, false, "no connection: Run is disabled")

    // One running.
    s = RunControlState(canRun: true, runningCount: 1, pulse: 0)
    expectEqual(s.runEnabled, true, "one running: another run is still allowed")
    expectEqual(s.cancelEnabled, true, "one running: Cancel is enabled")
    expectEqual(s.cancelAction, .cancelOne, "one running: Cancel stops it")
    expectEqual(s.tintStep, 0, "pulse 0 is the lowest tint step")
    expectEqual(s.cancelToolTip, "Cancel Query (⌘.)", "one running: tooltip")

    // Several running.
    s = RunControlState(canRun: true, runningCount: 3, pulse: 0.5)
    expectEqual(s.cancelAction, .showList, "three running: Cancel opens the list")
    expectEqual(s.cancelToolTip, "3 queries running — click to manage", "three running: tooltip names the count")
    expectEqual(s.cancelAccessibilityLabel, "Cancel 3 Queries", "three running: AX label names the count")
    expectEqual(s.tintStep, 6, "pulse 0.5 is the middle step (0.5 × 11 = 5.5, rounded)")

    // The pulse maps onto every step, clamped.
    expectEqual(RunControlState(canRun: true, runningCount: 1, pulse: 1).tintStep,
                RunControlState.tintSteps - 1, "pulse 1 (Reduce Motion's static value) is the top step")
    expectEqual(RunControlState(canRun: true, runningCount: 1, pulse: 7).tintStep,
                RunControlState.tintSteps - 1, "a pulse above 1 is clamped")
    expectEqual(RunControlState(canRun: true, runningCount: 1, pulse: -2).tintStep, 0, "a pulse below 0 is clamped")
    expectEqual(RunControlState(canRun: true, runningCount: -4, pulse: 1).cancelEnabled, false,
                "a negative count reads as idle")

    // Alphas: the tab dot's 0.55 + 0.45 · pulse.
    expectEqual(RunControlState.alpha(forStep: 0), 0.55, "the lowest step is the tab dot's lowest alpha")
    expectEqual(RunControlState.alpha(forStep: RunControlState.tintSteps - 1), 1.0, "the top step is solid")
    var rising = true
    for k in 1..<RunControlState.tintSteps where RunControlState.alpha(forStep: k) <= RunControlState.alpha(forStep: k - 1) {
        rising = false
    }
    expectEqual(rising, true, "alpha rises with every step")

    // Equality drives the control's change check.
    expectEqual(RunControlState(canRun: true, runningCount: 1, pulse: 0.50),
                RunControlState(canRun: true, runningCount: 1, pulse: 0.52),
                "two pulses on the same step are the same state (no image swap)")

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
