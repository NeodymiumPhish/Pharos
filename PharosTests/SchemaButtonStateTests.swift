// Standalone test runner for SchemaButtonState — the toolbar schema
// pull-down's title / enabled / spinner rule, per tab state.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func state(hasConnection: Bool = true, isConnected: Bool = true, isLoading: Bool = false,
                   hasSchemas: Bool = true, activeSchema: String? = nil) -> SchemaButtonState {
    SchemaButtonState(hasConnection: hasConnection, isConnected: isConnected, isLoading: isLoading,
                      hasSchemas: hasSchemas, activeSchema: activeSchema)
}

func runTests() {
    // No connection on the tab at all.
    var s = state(hasConnection: false, isConnected: false, hasSchemas: false)
    expectEqual(s.title, "No Schema", "a tab without a connection reads No Schema")
    expectEqual(s.isEnabled, false, "…and cannot be pressed")
    expectEqual(s.showsSpinner, false, "…and does not spin")

    // A connection named but not open (disconnected or failed).
    s = state(isConnected: false)
    expectEqual(s.title, "No Schema", "a tab whose connection is not open reads No Schema")
    expectEqual(s.isEnabled, false, "…and is disabled even though the cache has schemas")

    // Connected, metadata still loading.
    s = state(isLoading: true, hasSchemas: false)
    expectEqual(s.title, "Loading\u{2026}", "a connected tab shows Loading… while the cache fetches")
    expectEqual(s.isEnabled, false, "…disabled while loading")
    expectEqual(s.showsSpinner, true, "…with the spinner turning")

    // The shared cache is loading for ANOTHER window; this tab has no connection.
    s = state(hasConnection: false, isConnected: false, isLoading: true, hasSchemas: false)
    expectEqual(s.title, "No Schema", "another window's fetch does not put Loading… on an unconnected tab")
    expectEqual(s.showsSpinner, false, "…and does not spin here")

    // Connected, loaded, nothing pinned.
    s = state()
    expectEqual(s.title, "All Schemas", "connected with no pinned schema reads All Schemas")
    expectEqual(s.isEnabled, true, "…and can be pressed")
    expectEqual(s.showsSpinner, false, "…and does not spin")

    // Connected, loaded, a schema pinned.
    s = state(activeSchema: "analytics")
    expectEqual(s.title, "analytics", "the pinned schema is the title")
    expectEqual(s.isEnabled, true, "…enabled")

    // A hostile schema name is escaped for display.
    s = state(activeSchema: "evil\u{202E}name")
    expectEqual(s.title, DisplayEscape.escaped("evil\u{202E}name"), "the title goes through DisplayEscape")
    expectEqual(s.title.contains("\u{202E}"), false, "…so a bidi override does not reach the toolbar")

    // Connected but the database has no schemas the user can see.
    s = state(hasSchemas: false)
    expectEqual(s.title, "No Schema", "connected with an empty schema list reads No Schema")
    expectEqual(s.isEnabled, false, "…disabled")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
