// Standalone test for ResultLoadState — the row count's suffix and whether
// Load More / Load All are offered.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let complete = ResultLoadState(hasMore: false, limitReached: false)
    let more = ResultLoadState(hasMore: true, limitReached: false)
    let limit = ResultLoadState(hasMore: true, limitReached: true)
    expect(complete == .complete && complete.statusSuffix.isEmpty && !complete.showsLoadButtons,
           "the whole result: no suffix, no buttons")
    expect(more.statusSuffix == " (more available)" && more.showsLoadButtons, "more within the limit: buttons")
    expect(limit.statusSuffix == " (limit reached)" && !limit.showsLoadButtons, "at the limit: no buttons, says so")
    expect(ResultLoadState(hasMore: false, limitReached: true) == .complete,
           "nothing more on the server is complete, even if the flag was left on")

    expect(ResultLoadState.isAtLimit(rowCount: 500_000, hasMore: true, limit: 500_000), "Load All stopped at the limit")
    expect(!ResultLoadState.isAtLimit(rowCount: 500_000, hasMore: false, limit: 500_000), "exactly the limit, nothing more: complete")
    expect(!ResultLoadState.isAtLimit(rowCount: 3_000, hasMore: true, limit: 500_000), "paging below the limit")
    expect(ResultLoadState.isAtLimit(rowCount: 10_500, hasMore: true, limit: 10_000), "pages grew past the limit")

    expect(ResultLoadState.clampedLimit(500_000) == 500_000, "the default")
    expect(ResultLoadState.clampedLimit(5) == 1_000, "below the range")
    expect(ResultLoadState.clampedLimit(UInt32.max) == 5_000_000, "above the range")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
