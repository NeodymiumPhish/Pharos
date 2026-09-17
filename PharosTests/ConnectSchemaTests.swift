// Standalone test runner for ConnectSchema — which schema a connect lands on.
import Foundation

var failures = 0
func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

func runTests() {
    // The report this exists for: a restored tab linked to `tagtest` must
    // come back on `tagtest`, not on the connection's default.
    expectEqual(ConnectSchema.resolve(tabSchema: "tagtest", configured: "public", windowRemembered: "whois"),
                "tagtest", "the tab's own schema outranks the configured default and the window's memory")
    expectEqual(ConnectSchema.resolve(tabSchema: nil, configured: "whois", windowRemembered: "sales"),
                "whois", "a tab with no schema takes the configured default")
    expectEqual(ConnectSchema.resolve(tabSchema: nil, configured: "", windowRemembered: "sales"),
                "sales", "an empty configured default counts as none; the window's memory stands")
    expectEqual(ConnectSchema.resolve(tabSchema: nil, configured: nil, windowRemembered: nil),
                "public", "nothing anywhere → public")
    expectEqual(ConnectSchema.resolve(tabSchema: "tagtest", configured: nil, windowRemembered: nil),
                "tagtest", "the tab's schema stands alone")
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
