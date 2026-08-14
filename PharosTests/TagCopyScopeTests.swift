// Standalone test runner for TagCopyScope. Pure Foundation, no AppKit.
// Compiled with the implementation by scripts/test-tag-copy-scope.sh.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

func runTests() {
    let tagged: Set<Int> = [2, 5]

    // Toggle off: everything passes, tagged or not.
    expectTrue(TagCopyScope.include(dataRow: 2, taggedOnly: false, taggedRows: tagged),
               "toggle off passes a tagged row")
    expectTrue(TagCopyScope.include(dataRow: 3, taggedOnly: false, taggedRows: tagged),
               "toggle off passes an untagged row")
    expectTrue(TagCopyScope.include(dataRow: 3, taggedOnly: false, taggedRows: []),
               "toggle off with an empty tagged set passes every row")

    // Toggle on: only tagged rows pass.
    expectTrue(TagCopyScope.include(dataRow: 5, taggedOnly: true, taggedRows: tagged),
               "toggle on passes a tagged row")
    expectFalse(TagCopyScope.include(dataRow: 3, taggedOnly: true, taggedRows: tagged),
                "toggle on excludes an untagged row")
    expectFalse(TagCopyScope.include(dataRow: 0, taggedOnly: true, taggedRows: tagged),
                "toggle on excludes a row below every tagged index")

    // Every row tagged: the toggle changes nothing, but it must not invert.
    let allTagged: Set<Int> = [0, 1, 2]
    expectTrue(TagCopyScope.include(dataRow: 0, taggedOnly: true, taggedRows: allTagged),
               "toggle on passes the first row when every row is tagged")
    expectTrue(TagCopyScope.include(dataRow: 2, taggedOnly: true, taggedRows: allTagged),
               "toggle on passes the last row when every row is tagged")

    // Toggle on with NO tag map: pass-through, not exclude-everything. The
    // async recompute window briefly blanks the map; a ⌘C in that window must
    // not silently copy nothing. The menu item disables in this state too.
    expectTrue(TagCopyScope.include(dataRow: 3, taggedOnly: true, taggedRows: []),
               "toggle on with an empty tagged set passes every row")

    if failures == 0 {
        print("\nAll TagCopyScope tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
