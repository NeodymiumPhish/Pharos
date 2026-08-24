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

    // MARK: compile

    func condition(_ kind: TagConditionKind, _ family: String, _ value: String,
                   _ operand2: String? = nil) -> TagCondition {
        TagCondition(column: "c", family: family, kind: kind,
                     value: value, operand2: operand2, display: value)
    }

    // An exact condition is NOT a predicate: it goes in the hash index, so
    // compiling one is a caller mistake and returns nil.
    expect(TagPredicate.compile(condition(.exact, "text", "abc")) == nil,
           "an exact condition does not compile to a predicate")

    // An unsupported kind never compiles, so its rule is skipped whole.
    expect(TagPredicate.compile(condition(.unsupported("startsWith"), "text", "a")) == nil,
           "an unsupported kind does not compile")

    // Family and kind must agree.
    expect(TagPredicate.compile(condition(.glob, "numeric", "1*")) == nil,
           "glob does not compile against the numeric family")
    expect(TagPredicate.compile(condition(.glob, "address", "10.*")) == nil,
           "glob does not compile against the address family")
    expect(TagPredicate.compile(condition(.cidr, "numeric", "10.0.0.0/8")) == nil,
           "cidr does not compile against the numeric family")
    expect(TagPredicate.compile(condition(.greaterThan, "text", "5")) == nil,
           "a comparator does not compile against the text family")
    expect(TagPredicate.compile(condition(.greaterThan, "uuid", "5")) == nil,
           "a comparator does not compile against the uuid family")

    // Unparseable operands never compile, so nothing unparseable reaches the
    // row loop.
    expect(TagPredicate.compile(condition(.cidr, "address", "10.2.3.999")) == nil,
           "a malformed CIDR does not compile")
    expect(TagPredicate.compile(condition(.greaterThan, "numeric", "-Infinity")) == nil,
           "a non-numeric comparator operand does not compile")
    expect(TagPredicate.compile(condition(.greaterThan, "temporal", "3 days")) == nil,
           "an unparseable temporal operand does not compile")
    expect(TagPredicate.compile(condition(.between, "numeric", "10")) == nil,
           "between with no second operand does not compile")
    expect(TagPredicate.compile(condition(.between, "numeric", "10", "not a number")) == nil,
           "between with an unparseable upper bound does not compile")
    expect(TagPredicate.compile(condition(.glob, "text", #"abc\"#)) == nil,
           "a glob with a trailing lone backslash does not compile")

    // The happy paths DO compile.
    expect(TagPredicate.compile(condition(.glob, "text", "*.sh")) != nil, "a glob compiles")
    expect(TagPredicate.compile(condition(.cidr, "address", "10.0.0.0/8")) != nil, "a cidr compiles")
    expect(TagPredicate.compile(condition(.between, "numeric", "10", "20")) != nil,
           "between with both operands compiles")

    // MARK: matching

    func norm(_ text: String, _ family: String) -> String {
        TagValueNormalizer.normalize(text, family: family)
    }

    /// Compile a condition from RAW text (normalizing it as the real caller
    /// does), then test one raw cell of `cellFamily`.
    func hits(_ kind: TagConditionKind, _ family: String, _ value: String,
              _ operand2: String? = nil, cell: String, cellFamily: String) -> Bool {
        guard let predicate = TagPredicate.compile(
            condition(kind, family, norm(value, family), operand2.map { norm($0, family) }))
        else { return false }
        guard predicate.tests(family: cellFamily) else { return false }
        return predicate.matches(normalized: norm(cell, cellFamily), family: cellFamily)
    }

    // Glob, against text. This is the case the whole feature exists for.
    expect(hits(.glob, "text", "*.neodymiumphi.sh", cell: "network.neodymiumphi.sh", cellFamily: "text"),
           "glob matches a subdomain")
    expect(!hits(.glob, "text", "*.neodymiumphi.sh", cell: "neodymiumphi.sh", cellFamily: "text"),
           "glob does not match the bare domain")
    // Text normalization lowercases BOTH sides, so a glob is case-insensitive
    // for free and its metacharacters survive.
    expect(hits(.glob, "text", "*.NEODYMIUMPHI.SH", cell: "Network.NeodymiumPhi.sh", cellFamily: "text"),
           "glob is case-insensitive through normalization")

    // CIDR, against the address family AND against text.
    expect(hits(.cidr, "address", "107.8.8.0/24", cell: "107.8.8.1", cellFamily: "address"),
           "cidr matches an address cell")
    expect(hits(.cidr, "address", "107.8.8.0/24", cell: "107.8.8.1", cellFamily: "text"),
           "cidr also matches an address stored as text")
    expect(!hits(.cidr, "address", "107.8.8.0/24", cell: "107.8.9.1", cellFamily: "address"),
           "cidr rejects an address outside it")
    expect(!hits(.cidr, "address", "107.8.8.0/24", cell: "not an address", cellFamily: "text"),
           "cidr does not match arbitrary text")

    // Comparators, with the numeric byte-order trap as an explicit case.
    expect(hits(.greaterThan, "numeric", "9", cell: "10", cellFamily: "numeric"),
           "10 is greater than 9, which byte order gets wrong")
    expect(!hits(.greaterThan, "numeric", "10", cell: "9", cellFamily: "numeric"),
           "9 is not greater than 10")
    expect(hits(.lessThan, "numeric", "0", cell: "-5", cellFamily: "numeric"),
           "-5 is less than 0")
    expect(hits(.greaterOrEqual, "numeric", "1000", cell: "1000", cellFamily: "numeric"),
           "greaterOrEqual includes its bound")
    expect(!hits(.greaterThan, "numeric", "1000", cell: "1000", cellFamily: "numeric"),
           "greaterThan excludes its bound")
    expect(hits(.lessOrEqual, "numeric", "1000", cell: "1000", cellFamily: "numeric"),
           "lessOrEqual includes its bound")
    expect(hits(.between, "numeric", "1000", "2000", cell: "1500", cellFamily: "numeric"),
           "between matches inside")
    expect(hits(.between, "numeric", "1000", "2000", cell: "1000", cellFamily: "numeric"),
           "between includes its lower bound")
    expect(hits(.between, "numeric", "1000", "2000", cell: "2000", cellFamily: "numeric"),
           "between includes its upper bound")
    expect(!hits(.between, "numeric", "1000", "2000", cell: "2001", cellFamily: "numeric"),
           "between excludes past its upper bound")
    expect(!hits(.between, "numeric", "1000", "2000", cell: "999", cellFamily: "numeric"),
           "between excludes below its lower bound")

    // A CELL that fell back to raw text must NOT match a comparator, in EITHER
    // direction. A byte compare here is the false match the normalizer's gates
    // exist to prevent.
    expect(!hits(.greaterThan, "numeric", "0", cell: "-Infinity", cellFamily: "numeric"),
           "a fallen-back numeric cell never matches greaterThan")
    expect(!hits(.lessThan, "numeric", "0", cell: "-Infinity", cellFamily: "numeric"),
           "a fallen-back numeric cell never matches lessThan")
    expect(!hits(.between, "numeric", "0", "10", cell: "1,000", cellFamily: "numeric"),
           "a fallen-back numeric cell never matches between")

    // `-Infinity` above is a WEAK case against a byte compare, and deliberately
    // kept for the -infinity float8 scenario it names. But it sorts BELOW "0"
    // (0x2D against 0x30), so a byte compare answers "not greater" and is right
    // by accident. Every other fallen-back value sorts ABOVE "0", so this one
    // discriminates where that one cannot.
    expect(!hits(.greaterThan, "numeric", "0", cell: "1,000", cellFamily: "numeric"),
           "a fallen-back numeric cell that sorts high never matches greaterThan")

    // Temporal comparators.
    expect(hits(.greaterThan, "temporal", "2026-08-13 12:34:56.9",
                cell: "2026-08-13 12:34:56.91", cellFamily: "temporal"),
           ".91 is after .9, which byte order gets wrong")
    expect(hits(.between, "temporal", "2026-08-01", "2026-08-24",
                cell: "2026-08-13 12:34:56", cellFamily: "temporal"),
           "a timestamp falls between two dates")
    expect(!hits(.greaterThan, "temporal", "2026-08-01", cell: "12:34:56", cellFamily: "temporal"),
           "a bare time never matches a temporal comparator")

    // A predicate is only offered the families it can answer.
    let globPredicate = TagPredicate.compile(condition(.glob, "text", "a*"))!
    expect(globPredicate.tests(family: "text"), "glob tests text")
    expect(!globPredicate.tests(family: "numeric"), "glob does not test numeric")
    expect(!globPredicate.tests(family: "address"), "glob does not test address")
    let cidrPredicate = TagPredicate.compile(condition(.cidr, "address", "10.0.0.0/8"))!
    expect(cidrPredicate.tests(family: "address"), "cidr tests address")
    expect(cidrPredicate.tests(family: "text"), "cidr also tests text")
    expect(!cidrPredicate.tests(family: "numeric"), "cidr does not test numeric")
    let numberPredicate = TagPredicate.compile(condition(.greaterThan, "numeric", "5"))!
    expect(numberPredicate.tests(family: "numeric"), "a numeric comparator tests numeric")
    expect(!numberPredicate.tests(family: "text"), "a numeric comparator does NOT test text")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
