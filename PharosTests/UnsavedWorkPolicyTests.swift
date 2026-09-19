// Standalone test runner for `UnsavedWorkPolicy` — which editor tabs count as
// unsaved work, and the words the warning uses.
//
// The rule has three inputs that interact (dirty, bound, empty) plus the
// **Restore open tabs** setting, so the suite poses EVERY combination rather
// than the interesting ones: the case this feature exists to get right is the
// one where a warning would be a lie.
//
// Compiled by scripts/test-unsaved-work-policy.sh. Foundation only.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expect(_ condition: Bool, _ name: String) {
    expectEqual(condition, true, name)
}

private func tab(
    _ id: String = "t1", name: String = "Query 1",
    dirty: Bool, savedQuery: Bool = false, file: Bool = false, empty: Bool = false
) -> UnsavedWorkPolicy.Tab {
    UnsavedWorkPolicy.Tab(
        id: id, name: name, isDirty: dirty,
        hasSavedQuery: savedQuery, hasFile: file, isEmpty: empty)
}

// MARK: - The rule, over every combination

/// A clean tab is never unsaved, whatever it is bound to and whatever restore says.
private func testCleanTabNeverCounts() {
    for savedQuery in [false, true] {
        for file in [false, true] {
            for empty in [false, true] {
                for restore in [false, true] {
                    let t = tab(dirty: false, savedQuery: savedQuery, file: file, empty: empty)
                    expect(!UnsavedWorkPolicy.isUnsaved(t, restoreOpenTabs: restore),
                           "clean tab never counts (saved:\(savedQuery) file:\(file) empty:\(empty) restore:\(restore))")
                }
            }
        }
    }
}

/// An empty tab never counts, however dirty and however bound. Deleting the
/// last character is not work worth a dialog.
private func testEmptyTabNeverCounts() {
    for savedQuery in [false, true] {
        for file in [false, true] {
            for restore in [false, true] {
                let t = tab(dirty: true, savedQuery: savedQuery, file: file, empty: true)
                expect(!UnsavedWorkPolicy.isUnsaved(t, restoreOpenTabs: restore),
                       "empty dirty tab never counts (saved:\(savedQuery) file:\(file) restore:\(restore))")
            }
        }
    }
    // Named explicitly because it is the trap: restore OFF is the setting that
    // makes a dirty SCRATCH tab count, and an empty one must still not.
    expect(!UnsavedWorkPolicy.isUnsaved(tab(dirty: true, empty: true), restoreOpenTabs: false),
           "an EMPTY dirty scratch tab does NOT count even with restore off")
}

/// A dirty BOUND tab always counts: its edits have somewhere to go and have
/// not gone there, and restoring the session does not write them back.
private func testDirtyBoundTabAlwaysCounts() {
    for restore in [false, true] {
        expect(UnsavedWorkPolicy.isUnsaved(tab(dirty: true, savedQuery: true), restoreOpenTabs: restore),
               "dirty saved-query tab counts (restore:\(restore))")
        expect(UnsavedWorkPolicy.isUnsaved(tab(dirty: true, file: true), restoreOpenTabs: restore),
               "dirty file tab counts (restore:\(restore))")
        expect(UnsavedWorkPolicy.isUnsaved(tab(dirty: true, savedQuery: true, file: true), restoreOpenTabs: restore),
               "dirty tab bound to both counts (restore:\(restore))")
    }
}

/// The case the whole rule turns on: a dirty scratch tab is at risk only when
/// nothing will bring it back.
private func testDirtyScratchTabFollowsRestore() {
    expect(UnsavedWorkPolicy.isUnsaved(tab(dirty: true), restoreOpenTabs: false),
           "dirty scratch tab counts when restore is OFF")
    expect(!UnsavedWorkPolicy.isUnsaved(tab(dirty: true), restoreOpenTabs: true),
           "dirty scratch tab does NOT count when restore is ON")
}

// MARK: - The filter

private func testUnsavedFiltersAndKeepsOrder() {
    let tabs = [
        tab("a", name: "A", dirty: true, savedQuery: true),   // counts always
        tab("b", name: "B", dirty: false, savedQuery: true),  // clean
        tab("c", name: "C", dirty: true),                     // scratch
        tab("d", name: "D", dirty: true, file: true),         // counts always
        tab("e", name: "E", dirty: true, empty: true),        // empty
    ]
    expectEqual(UnsavedWorkPolicy.unsaved(in: tabs, restoreOpenTabs: true).map(\.id),
                ["a", "d"], "with restore on, only the bound dirty tabs")
    expectEqual(UnsavedWorkPolicy.unsaved(in: tabs, restoreOpenTabs: false).map(\.id),
                ["a", "c", "d"], "with restore off, the dirty scratch tab joins them")
    expectEqual(UnsavedWorkPolicy.unsaved(in: [], restoreOpenTabs: false).count, 0,
                "no tabs, nothing to warn about")
    expectEqual(UnsavedWorkPolicy.unsaved(in: tabs, restoreOpenTabs: true).map(\.name),
                ["A", "D"], "the tabs come back whole, in the order given")
}

// MARK: - Where Save can write

private func testCanSaveInPlace() {
    expect(UnsavedWorkPolicy.canSaveInPlace(tab(dirty: true, savedQuery: true)), "a saved query can be written back")
    expect(UnsavedWorkPolicy.canSaveInPlace(tab(dirty: true, file: true)), "a file can be written back")
    expect(!UnsavedWorkPolicy.canSaveInPlace(tab(dirty: true)), "a scratch tab needs the Save Query sheet")
}

// MARK: - Alert text

private func testAlertText() {
    let one = [tab("a", name: "Monthly report", dirty: true, savedQuery: true)]
    expect(UnsavedWorkPolicy.alertTitle(for: one).contains("Monthly report"),
           "one tab is named in the title")
    expectEqual(UnsavedWorkPolicy.alertMessage(for: one),
                "Your changes will be lost if you don't save them.",
                "one tab needs no list")
    expectEqual(UnsavedWorkPolicy.saveButtonTitle(for: one), "Save", "one tab: Save")

    let many = [
        tab("a", name: "Monthly report", dirty: true, savedQuery: true),
        tab("b", name: "adhoc.sql", dirty: true, file: true),
    ]
    expect(UnsavedWorkPolicy.alertTitle(for: many).contains("2"), "several tabs are counted in the title")
    expect(UnsavedWorkPolicy.alertMessage(for: many).contains("Monthly report"), "the list names the first")
    expect(UnsavedWorkPolicy.alertMessage(for: many).contains("adhoc.sql"), "the list names the second")
    expectEqual(UnsavedWorkPolicy.saveButtonTitle(for: many), "Save All", "several tabs: Save All")

    expectEqual(UnsavedWorkPolicy.dontSaveButtonTitle, "Don't Save", "the discard button")
    expectEqual(UnsavedWorkPolicy.cancelButtonTitle, "Cancel", "the cancel button")
}

func runTests() {
    testCleanTabNeverCounts()
    testEmptyTabNeverCounts()
    testDirtyBoundTabAlwaysCounts()
    testDirtyScratchTabFollowsRestore()
    testUnsavedFiltersAndKeepsOrder()
    testCanSaveInPlace()
    testAlertText()

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
