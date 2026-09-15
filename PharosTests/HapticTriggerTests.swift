// Standalone test for Haptics — no Xcode project involvement. Compiled by
// scripts/test-haptic-trigger.sh.
//
// What this suite is FOR: the two pure decision functions that gate every
// haptic call site (`shouldTap`, generic over the nested `ContentExpandState`
// enum via a local mirror type, and `shouldTapForFolderDrop`) must fire on
// exactly the cases the design calls for — a real state change away from
// `normal`, and at least one query landing in a different folder — and stay
// silent otherwise (no-op drags, same-folder drops, an empty move list).
// It also proves `Haptics.alignment()` calls the injected performer exactly
// once per call, which is the only way to observe the real haptic without
// touching trackpad hardware.
import Foundation

var failures = 0

private func expect(_ actual: Bool, _ expected: Bool, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

// Local mirror of ContentViewController.ContentExpandState — that enum is
// nested inside a large AppKit view controller with FFI dependencies this
// standalone binary cannot compile. Haptics.shouldTap is generic over
// Equatable specifically so it needs no such mirror in production; this
// enum exists only to exercise it here with the same shape (three cases,
// one of them "normal").
private enum ExpandState: Equatable {
    case normal, editorExpanded, resultsExpanded
}

// MARK: - shouldTap (expand state)

private func testExpandStateAllPairs() {
    let states: [ExpandState] = [.normal, .editorExpanded, .resultsExpanded]
    for from in states {
        for to in states {
            let expected = (from != to) && (from != .normal)
            let actual = Haptics.shouldTap(from: from, to: to, normal: ExpandState.normal)
            expect(actual, expected, "shouldTap(from: \(from), to: \(to))")
        }
    }
}

private func testExpandStateSameStateIsSilent() {
    expect(Haptics.shouldTap(from: ExpandState.editorExpanded, to: .editorExpanded, normal: .normal), false,
           "no change (editorExpanded -> editorExpanded) is silent")
    expect(Haptics.shouldTap(from: ExpandState.normal, to: .normal, normal: .normal), false,
           "no change (normal -> normal) is silent")
}

private func testExpandStateEnteringAnExpandedStateIsSilent() {
    // The design fires only when LEAVING an expanded state (the divider-drag
    // call site), never when entering one (the expand buttons / launch
    // restore reach this same transition without a drag).
    expect(Haptics.shouldTap(from: ExpandState.normal, to: .editorExpanded, normal: .normal), false,
           "normal -> editorExpanded (entering) is silent")
    expect(Haptics.shouldTap(from: ExpandState.normal, to: .resultsExpanded, normal: .normal), false,
           "normal -> resultsExpanded (entering) is silent")
}

private func testExpandStateLeavingExpandedForNormalTaps() {
    expect(Haptics.shouldTap(from: ExpandState.editorExpanded, to: .normal, normal: .normal), true,
           "leaving editorExpanded for normal taps (the divider-drag call site)")
    expect(Haptics.shouldTap(from: ExpandState.resultsExpanded, to: .normal, normal: .normal), true,
           "leaving resultsExpanded for normal taps (the divider-drag call site)")
}

// MARK: - shouldTapForFolderDrop

private func testFolderDropEmptyListIsSilent() {
    expect(Haptics.shouldTapForFolderDrop(moves: []), false, "an empty move list is silent")
}

private func testFolderDropSameFolderIsSilent() {
    expect(Haptics.shouldTapForFolderDrop(moves: [(from: "Reports", to: "Reports")]), false,
           "dropping back into the same named folder is silent")
    expect(Haptics.shouldTapForFolderDrop(moves: [(from: nil, to: nil)]), false,
           "dropping back into no folder (nil -> nil) is silent")
}

private func testFolderDropDifferentFolderTaps() {
    expect(Haptics.shouldTapForFolderDrop(moves: [(from: nil, to: "Reports")]), true,
           "nil -> \"Reports\" taps")
    expect(Haptics.shouldTapForFolderDrop(moves: [(from: "Reports", to: nil)]), true,
           "\"Reports\" -> nil taps")
    expect(Haptics.shouldTapForFolderDrop(moves: [(from: "A", to: "B")]), true,
           "\"A\" -> \"B\" taps")
}

private func testFolderDropMultiMoveOnlyOneDifferentTaps() {
    let moves: [(from: String?, to: String?)] = [
        (from: "Reports", to: "Reports"),
        (from: "Reports", to: "Reports"),
        (from: nil, to: "Archive"),
    ]
    expect(Haptics.shouldTapForFolderDrop(moves: moves), true,
           "a multi-move drop taps when only one query actually changed folder")
}

private func testFolderDropMultiMoveAllSameIsSilent() {
    let moves: [(from: String?, to: String?)] = [
        (from: "Reports", to: "Reports"),
        (from: nil, to: nil),
    ]
    expect(Haptics.shouldTapForFolderDrop(moves: moves), false,
           "a multi-move drop stays silent when every query landed back where it started")
}

// MARK: - Haptics.alignment() calls the injected performer exactly once

private func testAlignmentCallsPerformerExactlyOnce() {
    var callCount = 0
    let original = Haptics.performer
    Haptics.performer = { callCount += 1 }
    defer { Haptics.performer = original }

    Haptics.alignment()
    expect(callCount == 1, true, "Haptics.alignment() calls the injected performer exactly once")
}

private func testAlignmentDoesNotFireExtraCalls() {
    var callCount = 0
    let original = Haptics.performer
    Haptics.performer = { callCount += 1 }
    defer { Haptics.performer = original }

    Haptics.alignment()
    Haptics.alignment()
    expect(callCount == 2, true, "two separate alignment() calls invoke the performer twice, not more")
}

func runTests() {
    testExpandStateAllPairs()
    testExpandStateSameStateIsSilent()
    testExpandStateEnteringAnExpandedStateIsSilent()
    testExpandStateLeavingExpandedForNormalTaps()
    testFolderDropEmptyListIsSilent()
    testFolderDropSameFolderIsSilent()
    testFolderDropDifferentFolderTaps()
    testFolderDropMultiMoveOnlyOneDifferentTaps()
    testFolderDropMultiMoveAllSameIsSilent()
    testAlignmentCallsPerformerExactlyOnce()
    testAlignmentDoesNotFireExtraCalls()

    print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
    exit(failures == 0 ? 0 : 1)
}
