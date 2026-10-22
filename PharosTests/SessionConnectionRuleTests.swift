// Standalone test for SessionConnectionRule — compiled by
// scripts/test-session-connection-rule.sh.
import Foundation

private var failures = 0
private func expect(_ c: Bool, _ name: String) {
    if c { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    let known: Set<String> = ["prod", "sales"]
    let own = SessionConnectionRule.resolve(connectionId: "sales", schemaName: "main", exists: known.contains)
    expect(own.connectionId == "sales" && own.schemaName == "main", "its own connection and schema, when the record exists")
    let gone = SessionConnectionRule.resolve(connectionId: "deleted", schemaName: "public", exists: known.contains)
    expect(gone.connectionId == nil && gone.schemaName == nil, "a deleted record: no connection, no schema")
    let never = SessionConnectionRule.resolve(connectionId: nil, schemaName: nil, exists: known.contains)
    expect(never.connectionId == nil && never.schemaName == nil, "a Session with no connection: none")
    if failures == 0 { print("\nAll session connection rule tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
