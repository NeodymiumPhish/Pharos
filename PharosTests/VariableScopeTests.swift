// Standalone test for VariableScope — compiled by scripts/test-variable-scope.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let limit = QueryVariable(name: "limit", value: "50")
    let env = QueryVariable(name: "env", value: "prod", connectionIds: ["prod", "staging"])
    let ip = QueryVariable(name: "ip", value: "10.0.0.1", connectionIds: ["file-1"])
    let all = [limit, env, ip]

    expect(VariableScope.available(all, connectionId: "prod").map(\.name), ["limit", "env"],
           "a tab on Prod: the global ones and those linked to Prod")
    expect(VariableScope.available(all, connectionId: "file-1").map(\.name), ["limit", "ip"],
           "a tab on an opened file: its linked ones too")
    expect(VariableScope.available(all, connectionId: "other").map(\.name), ["limit"], "another connection: globals only")
    expect(VariableScope.available(all, connectionId: nil).map(\.name), ["limit"], "no connection: globals only")

    expect(VariableScope.linkedElsewhere(name: "env", in: all, connectionId: "other"), ["prod", "staging"],
           "linked elsewhere: where it is defined")
    expect(VariableScope.linkedElsewhere(name: "env", in: all, connectionId: "prod"), nil, "available here: no error")
    expect(VariableScope.linkedElsewhere(name: "limit", in: all, connectionId: nil), nil, "a global one is never elsewhere")
    expect(VariableScope.linkedElsewhere(name: "nope", in: all, connectionId: nil), nil, "a missing one is plain undefined")
    expect(VariableScope.linkedElsewhereMessage(name: "env", connectionNames: ["Prod", "Staging"]),
           "{{env}} is linked to Prod and Staging, not to this tab's connection.", "the error text")
    expect(VariableScope.linkedElsewhereMessage(name: "env", connectionNames: []),
           "{{env}} is linked to connections that no longer exist, not to this tab's connection.",
           "linked records that are gone")

    // The core's JSON: the key is left out for a global variable, present for a linked one.
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    let globalJSON = String(data: try! enc.encode(limit), encoding: .utf8)!
    expect(globalJSON.contains("connectionIds"), false, "a global variable's JSON has no connectionIds key")
    let linkedJSON = String(data: try! enc.encode(env), encoding: .utf8)!
    expect(linkedJSON.contains(#""connectionIds":["prod","staging"]"#), true, "a linked one carries its ids")
    let back = try? JSONDecoder().decode(QueryVariable.self, from: Data(linkedJSON.utf8))
    expect(back?.connectionIds, ["prod", "staging"], "and reads them back")
    let old = try? JSONDecoder().decode(QueryVariable.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"x"}"#.utf8))
    expect(old?.isGlobal, true, "a variable written before scopes is global")

    if failures == 0 { print("\nAll variable scope tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
