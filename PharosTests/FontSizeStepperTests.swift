// Standalone test for FontSizeStepper — no Xcode project involvement.
// Compiled by scripts/test-font-size-stepper.sh.
//
// What this suite is FOR: the pinch-to-step arithmetic must truncate partial
// gestures toward zero (a small pinch does nothing), fire exactly one step
// per 0.25 of magnification in either direction, and clamp to 9...24 from
// both sides — the one number a live pinch cannot prove, so it is proven
// here instead. `stepped` (the ⌘+/⌘− path) gets the same clamp coverage.
import Foundation

var failures = 0

private func expect(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func testZeroMagnificationDoesNotStep() {
    expect(FontSizeStepper.size(start: 13, magnification: 0), 13, "zero magnification does not step")
}

private func testPartialMagnificationDoesNotStep() {
    expect(FontSizeStepper.size(start: 13, magnification: 0.24), 13, "+0.24 does not reach a step")
    expect(FontSizeStepper.size(start: 13, magnification: -0.24), 13, "-0.24 does not reach a step")
}

private func testOneStepAtThreshold() {
    expect(FontSizeStepper.size(start: 13, magnification: 0.25), 14, "+0.25 steps up by one")
    expect(FontSizeStepper.size(start: 13, magnification: -0.25), 12, "-0.25 steps down by one")
}

private func testFourStepsAtOneMagnitude() {
    expect(FontSizeStepper.size(start: 13, magnification: 1.0), 17, "+1.0 steps up by four")
    expect(FontSizeStepper.size(start: 13, magnification: -1.0), 9, "-1.0 steps down by four")
}

private func testClampsAtUpperBoundFromMagnification() {
    expect(FontSizeStepper.size(start: 23, magnification: 1.0), 24, "a pinch past 24 clamps at 24")
}

private func testClampsAtLowerBoundFromMagnification() {
    expect(FontSizeStepper.size(start: 10, magnification: -1.0), 9, "a pinch past 9 clamps at 9")
}

private func testSteppedMovesByOne() {
    expect(FontSizeStepper.stepped(15, by: 1), 16, "stepped(+1) moves up by one")
    expect(FontSizeStepper.stepped(15, by: -1), 14, "stepped(-1) moves down by one")
}

private func testSteppedClampsAtUpperBound() {
    expect(FontSizeStepper.stepped(24, by: 1), 24, "stepped(+1) at the max clamps")
}

private func testSteppedClampsAtLowerBound() {
    expect(FontSizeStepper.stepped(9, by: -1), 9, "stepped(-1) at the min clamps")
}

func runTests() {
    testZeroMagnificationDoesNotStep()
    testPartialMagnificationDoesNotStep()
    testOneStepAtThreshold()
    testFourStepsAtOneMagnitude()
    testClampsAtUpperBoundFromMagnification()
    testClampsAtLowerBoundFromMagnification()
    testSteppedMovesByOne()
    testSteppedClampsAtUpperBound()
    testSteppedClampsAtLowerBound()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
