// Standalone test runner for TabNaming — a query tab's automatic name.
import Foundation

var failures = 0
func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

func runTests() {
    // New Tab N
    expectEqual(TabNaming.nextNewTabName(used: []), "New Tab 1", "no tabs → New Tab 1")
    expectEqual(TabNaming.nextNewTabName(used: ["New Tab 1"]), "New Tab 2", "the next number")
    expectEqual(TabNaming.nextNewTabName(used: ["New Tab 2", "analytics - public"]), "New Tab 1",
                "a number given back (the tab connected) is used again")
    expectEqual(TabNaming.nextNewTabName(used: ["New Tab 1", "New Tab 3"]), "New Tab 2", "the lowest free number")
    expectEqual(TabNaming.nextNewTabName(used: ["New Tab", "New Tab 01", "Query 1"]), "New Tab 1",
                "only whole \"New Tab N\" names take a number")

    // {connection} - {schema}
    expectEqual(TabNaming.automaticName(connection: "Prod", schema: "public"), "Prod - public", "connection and schema")
    expectEqual(TabNaming.automaticName(connection: "Prod", database: "analytics", schema: "public"), "Prod - public",
                "the connection NAME, not the database field")
    expectEqual(TabNaming.automaticName(connection: "Prod", schema: nil), "Prod", "no schema → the connection alone")
    expectEqual(TabNaming.automaticName(connection: "Prod", schema: "  "), "Prod", "a blank schema counts as none")
    expectEqual(TabNaming.automaticName(connection: "  Prod ", schema: "public"), "Prod - public", "the name is trimmed")
    expectEqual(TabNaming.automaticName(connection: "", database: "analytics", schema: "public"), "analytics - public",
                "an empty connection name → the database field")
    expectEqual(TabNaming.automaticName(connection: "", schema: "main"), "main", "nothing but a schema → the schema")

    // Numbers
    expectEqual(TabNaming.numbered("Prod - public", taken: []), "Prod - public", "a free name has no number")
    expectEqual(TabNaming.numbered("Prod - public", taken: ["Prod - public"]), "Prod - public (2)", "the second tab is (2)")
    expectEqual(TabNaming.numbered("Prod - public", taken: ["Prod - public", "Prod - public (2)"]), "Prod - public (3)",
                "the third is (3)")
    expectEqual(TabNaming.numbered("Prod - public", taken: ["Prod - public", "Prod - public (3)"]), "Prod - public (2)",
                "the lowest free number")
    expectEqual(TabNaming.numbered("Prod - public", taken: ["Prod - public (2)"]), "Prod - public",
                "the plain name, when it is free, comes first")
    expectEqual(TabNaming.numbered("Prod - public", taken: ["Prod - sales", "Staging - public"]), "Prod - public",
                "other connections and schemas do not count")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
