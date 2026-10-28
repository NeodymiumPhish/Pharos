// Standalone test for VariableMenuPreview (the Variables pull-down's
// "Renders as" row). Compiled by scripts/test-variable-menu-preview.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func v(_ name: String, _ value: String, _ type: VariableType = .literal) -> QueryVariable {
    QueryVariable(name: name, value: value, type: type)
}

func runTests() {
    typealias P = VariableMenuPreview
    expect(P.preview(for: "router", variables: []) == .undefined, "undefined")
    expect(P.preview(for: "router", variables: [v("router", "12.32.64.52")]) == .value("12.32.64.52", truncated: false),
           "literal value", "\(P.preview(for: "router", variables: [v("router", "12.32.64.52")]))")
    expect(P.preview(for: "h", variables: [v("h", "10.0.0.1", .text)]) == .value("'10.0.0.1'", truncated: false),
           "text renders quoted, as the query gets it", "\(P.preview(for: "h", variables: [v("h", "10.0.0.1", .text)]))")
    expect(P.preview(for: "l", variables: [v("l", "a\nb", .textList)]) == .value("('a', 'b')", truncated: false),
           "list renders as the IN list", "\(P.preview(for: "l", variables: [v("l", "a\nb", .textList)]))")
    expect(P.preview(for: "e", variables: [v("e", "  ")]) == .empty, "blank literal renders nothing")
    if case .invalid = P.preview(for: "d", variables: [v("d", "2026-02-30", .date)]) {
        expect(true, "invalid date says why")
    } else { expect(false, "invalid date says why") }
    expect(P.preview(for: "m", variables: [v("m", "\n  first line\nsecond")]) == .value("first line", truncated: true),
           "first line with content; more lines mark it cut", "\(P.preview(for: "m", variables: [v("m", "\n  first line\nsecond")]))")
    let long = String(repeating: "x", count: 100)
    expect(P.preview(for: "x", variables: [v("x", long)]) == .value(String(repeating: "x", count: P.limit), truncated: true),
           "long value capped")
    expect(P.preview(for: "d", variables: [v("d", "1"), v("d", "2")]) == .value("2", truncated: false),
           "last definition wins, as in render")
    expect(P.text(.value("abc", truncated: true)).hasSuffix("abc…"), "text: ellipsis when cut", P.text(.value("abc", truncated: true)))

    if failures > 0 {
        print("\(failures) FAILED")
        exit(1)
    }
    print("ALL PASS")
}
