// Standalone test for TagConditionKind, and later TagPredicate.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // MARK: kind round trip

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// Decode a bare JSON string into a kind, then re-encode it.
    func roundTrip(_ raw: String) -> (kind: TagConditionKind, encoded: String)? {
        guard let data = "\"\(raw)\"".data(using: .utf8),
              let kind = try? decoder.decode(TagConditionKind.self, from: data),
              let out = try? encoder.encode(kind),
              let text = String(data: out, encoding: .utf8)
        else { return nil }
        return (kind, text)
    }

    expect(roundTrip("exact")?.kind == .exact, "exact decodes")
    expect(roundTrip("glob")?.kind == .glob, "glob decodes")
    expect(roundTrip("cidr")?.kind == .cidr, "cidr decodes")
    expect(roundTrip("greaterThan")?.kind == .greaterThan, "greaterThan decodes")
    expect(roundTrip("greaterOrEqual")?.kind == .greaterOrEqual, "greaterOrEqual decodes")
    expect(roundTrip("lessThan")?.kind == .lessThan, "lessThan decodes")
    expect(roundTrip("lessOrEqual")?.kind == .lessOrEqual, "lessOrEqual decodes")
    expect(roundTrip("between")?.kind == .between, "between decodes")

    // Every known kind survives a round trip byte for byte.
    for raw in ["exact", "glob", "cidr", "greaterThan", "greaterOrEqual",
                "lessThan", "lessOrEqual", "between"] {
        expect(roundTrip(raw)?.encoded == "\"\(raw)\"", "\(raw) re-encodes unchanged")
    }

    // THE case that protects stored data. An unknown kind must NOT throw, and
    // it must re-encode byte for byte — a newer build's rule survives a round
    // trip through this one intact.
    expect(roundTrip("startsWith")?.kind == .unsupported("startsWith"),
           "an unknown kind decodes as unsupported, not a throw")
    expect(roundTrip("startsWith")?.encoded == "\"startsWith\"",
           "an unknown kind re-encodes byte for byte")

    // Decoding an unknown kind must not throw even when asked directly.
    let unknownData = "\"neverHeardOfIt\"".data(using: .utf8)!
    var threw = false
    do { _ = try decoder.decode(TagConditionKind.self, from: unknownData) }
    catch { threw = true }
    expect(!threw, "decoding an unknown kind does not throw")

    // An unsupported kind is never confused with a known one.
    expect(TagConditionKind.unsupported("glob") != TagConditionKind.glob,
           "unsupported(glob) is not glob")
    expect(TagConditionKind.unsupported("a") != TagConditionKind.unsupported("b"),
           "two different unsupported kinds differ")

    // `isSupported` is what a later task uses to skip a rule it cannot evaluate.
    expect(TagConditionKind.exact.isSupported, "exact is supported")
    expect(TagConditionKind.between.isSupported, "between is supported")
    expect(!TagConditionKind.unsupported("x").isSupported, "an unknown kind is not supported")

    // `known` lists exactly the eight this build can evaluate, in picker order.
    expect(TagConditionKind.known.count == 8, "eight known kinds")
    expect(TagConditionKind.known.allSatisfy { $0.isSupported }, "every known kind is supported")
    expect(TagConditionKind.known.first == .exact, "exact leads the picker order")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
