// Standalone test runner for SQLTheme's named catalogue. Not part of the app
// target — compiled together with the implementation by
// scripts/test-sql-theme-catalog.sh.
//
// The load-bearing promise: `"system"` is TODAY'S colours, exactly. A user who
// has never opened Settings ▸ Editor ▸ Colours must see the editor they have
// always seen, so each role is compared component by component against the
// literal colour the highlighter used before the catalogue existed — not
// against `SQLTheme.default`, which would pass even if both moved together.
import AppKit

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// A colour's red/green/blue/alpha in sRGB, resolved for one appearance.
///
/// The roles are system colours, which are DYNAMIC: they answer differently
/// in light and dark. Resolving explicitly means the comparison is a real
/// numeric one rather than a comparison of two unresolved catalogue names.
func components(_ color: NSColor, _ appearance: NSAppearance) -> [CGFloat] {
    var out: [CGFloat] = []
    appearance.performAsCurrentDrawingAppearance {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        out = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
    return out
}

/// Whether two colours resolve identically in BOTH appearances.
func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        guard let appearance = NSAppearance(named: name) else { return false }
        let lhs = components(a, appearance)
        let rhs = components(b, appearance)
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        for (x, y) in zip(lhs, rhs) where abs(x - y) > 0.0005 { return false }
    }
    return true
}

func runTests() {
    // ---- every offered name resolves to its own entry ----
    for entry in SQLTheme.catalog {
        expect(sameColor(SQLTheme.named(entry.name).keyword, entry.theme.keyword),
               "named(\"\(entry.name)\") resolves to that entry")
        expect(!entry.displayLabel.isEmpty, "\(entry.name) has a title")
    }
    expect(SQLTheme.availableNames == SQLTheme.catalog.map(\.name),
           "availableNames is the catalogue, in order")
    expect(SQLTheme.availableNames.count >= 3,
           "the catalogue offers System plus at least two more",
           "got \(SQLTheme.availableNames)")

    // ---- the names are unique ----
    expect(Set(SQLTheme.availableNames).count == SQLTheme.availableNames.count,
           "no two themes share a stored name", "got \(SQLTheme.availableNames)")
    let labels = SQLTheme.catalog.map(\.displayLabel)
    expect(Set(labels).count == labels.count,
           "no two themes share a title", "got \(labels)")

    // ---- an unknown name falls back to the System theme ----
    for unknown in ["", "solarized", "System", "vivid "] {
        expect(sameColor(SQLTheme.named(unknown).keyword, SQLTheme.default.keyword),
               "an unknown name (\"\(unknown)\") gives the System theme")
    }
    expect(SQLTheme.displayLabel(for: "nope") == SQLTheme.catalog[0].displayLabel,
           "an unknown name shows the System title")

    // ---- "system" is TODAY'S colours, role by role ----
    let system = SQLTheme.named(SQLTheme.systemThemeName)
    let today: [(String, NSColor, NSColor)] = [
        ("keyword", system.keyword, .systemBlue),
        ("function", system.function, .systemTeal),
        ("string", system.string, .systemGreen),
        ("number", system.number, .systemOrange),
        ("comment", system.comment, .systemGray),
        ("type", system.type, .systemPurple),
        ("variable", system.variable, .systemIndigo),
        ("variableUnresolved", system.variableUnresolved, .systemRed),
    ]
    for (role, actual, expected) in today {
        expect(sameColor(actual, expected),
               "system's \(role) is the colour the editor has always used",
               "light \(components(actual, NSAppearance(named: .aqua)!)) "
                   + "vs \(components(expected, NSAppearance(named: .aqua)!))")
    }

    // The settings default and the catalogue's own name are the same string.
    // They are written out separately (Settings.swift stays Foundation-only),
    // so nothing but this test holds them together.
    expect(EditorSettings().syntaxTheme == SQLTheme.systemThemeName,
           "EditorSettings' default theme name is the System theme's name",
           "settings says \"\(EditorSettings().syntaxTheme)\", "
               + "the catalogue says \"\(SQLTheme.systemThemeName)\"")
    expect(SQLTheme.availableNames.contains(EditorSettings().syntaxTheme),
           "the default theme name is one the catalogue offers")

    // ---- the extra themes really are different ----
    for entry in SQLTheme.catalog.dropFirst() {
        expect(!sameColor(entry.theme.keyword, SQLTheme.default.keyword),
               "\(entry.name) is not a copy of System")
    }

    if failures > 0 {
        print("\n\(failures) FAILED")
        exit(1)
    }
    print("\nALL PASSED")
}
