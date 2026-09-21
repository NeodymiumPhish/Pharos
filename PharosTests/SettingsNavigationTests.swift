// Standalone test runner for the Settings window's pure navigation types:
// the pane registry, the back/forward history and the remembered pane.
// Compiled by scripts/test-settings-navigation.sh. No FFI, no view code.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func testHistory() {
    var h = SettingsNavigationHistory()
    expectEqual(h.current, nil, "history starts empty")
    expectTrue(!h.canGoBack && !h.canGoForward, "both ends disabled at the start")
    expectEqual(h.goBack(), nil, "goBack at the start returns nil")
    expectEqual(h.goForward(), nil, "goForward at the start returns nil")

    h.visit(.general); h.visit(.editor); h.visit(.query)
    expectEqual(h.current, .query, "visit sets current")
    expectTrue(h.canGoBack && !h.canGoForward, "after three visits: back yes, forward no")

    let before = h
    h.visit(.query)
    expectEqual(h, before, "visiting the current pane is a no-op")

    expectEqual(h.goBack(), .editor, "goBack returns the previous pane")
    expectEqual(h.goBack(), .general, "goBack again")
    expectEqual(h.goBack(), nil, "goBack at the first entry returns nil")
    expectTrue(!h.canGoBack && h.canGoForward, "at the start of a list: back no, forward yes")
    expectEqual(h.goForward(), .editor, "goForward returns the next pane")

    // From the middle, a new visit truncates what was ahead.
    h.visit(.charts)
    expectEqual(h.entries, [.general, .editor, .charts], "visit from the middle drops the forward entries")
    expectTrue(!h.canGoForward, "nothing ahead after a fresh visit")

    // Cap at 50.
    var long = SettingsNavigationHistory()
    let cycle = SettingsPaneID.allCases
    for i in 0..<120 { long.visit(cycle[i % cycle.count]) }
    expectEqual(long.entries.count, SettingsNavigationHistory.capacity, "history is capped at 50")
    expectEqual(long.current, cycle[119 % cycle.count], "the current pane survives the cap")
    var steps = 0
    while long.goBack() != nil { steps += 1 }
    expectEqual(steps, SettingsNavigationHistory.capacity - 1, "49 steps back from a full history")
}

private func testPrefs() {
    let suite = "PharosSettingsNavigationTests.\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max))"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .general, "no stored value → General")

    SettingsPanePrefs.setLastPane(.results, in: defaults)
    expectEqual(defaults.string(forKey: SettingsPanePrefs.key), "results", "stored as the raw value string")
    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .results, "last-pane round trip")

    defaults.set(2, forKey: SettingsPanePrefs.key)
    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .query, "legacy Int 2 maps to Query")
    defaults.set(3, forKey: SettingsPanePrefs.key)
    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .charts, "legacy Int 3 maps to Charts")
    defaults.set(9, forKey: SettingsPanePrefs.key)
    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .general, "legacy Int out of range → General")

    defaults.set("no-such-pane", forKey: SettingsPanePrefs.key)
    expectEqual(SettingsPanePrefs.lastPane(in: defaults), .general, "unknown string → General")
}

private func testRegistry() {
    let all = SettingsPaneRegistry.all
    expectEqual(all.count, SettingsPaneID.allCases.count, "the registry has one spec per pane id")
    expectEqual(all.map(\.id), SettingsPaneID.allCases, "registry order is the enum order (the sidebar order)")
    expectEqual(Set(all.map(\.id)).count, all.count, "registry ids are unique")
    expectEqual(Set(all.map(\.title)).count, all.count, "registry titles are unique")
    for spec in all {
        expectTrue(NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil) != nil,
                   "symbol `\(spec.symbol)` resolves")
        expectTrue(!spec.title.isEmpty, "\(spec.id) has a title")
    }
    expectEqual(SettingsPaneID.general.rowIdentifier, "settings.pane.general", "the General row keeps its identifier")
    expectEqual(SettingsPaneID.charts.rowIdentifier, "settings.pane.charts", "the Charts row keeps its identifier")
    expectEqual(SettingsPaneRegistry.spec(for: .advanced).id, .advanced, "spec(for:) finds the pane")

    // About is the end of the list, not a setting, so it must stay last.
    expectEqual(SettingsPaneID.allCases.last, .about, "About is the last row in the sidebar")
    expectEqual(SettingsPaneRegistry.all.last?.id, .about, "…and the last spec in the registry")
    expectEqual(SettingsPaneID.about.rowIdentifier, "settings.pane.about", "the About row's identifier")
    expectEqual(SettingsPaneRegistry.spec(for: .about).title, "About", "the About row is titled About")
}

/// The two rules `SettingsSplitViewController.navigate(to:source:)` reads off
/// the source. They live here because that controller pulls in the whole app.
private func testNavigationSources() {
    expectTrue(SettingsNavigationSource.user.recordsHistory, "a sidebar click is a history entry")
    expectTrue(SettingsNavigationSource.deepLink.recordsHistory,
               "a deep link is a history entry, so Back returns to where the window opened")
    expectTrue(!SettingsNavigationSource.history.recordsHistory, "Back/Forward moves within the history")
    expectTrue(!SettingsNavigationSource.restore.recordsHistory, "restoring is the root, seeded separately")

    expectTrue(SettingsNavigationSource.user.isRemembered, "a sidebar click is remembered")
    expectTrue(SettingsNavigationSource.history.isRemembered, "Back/Forward is remembered")
    expectTrue(!SettingsNavigationSource.restore.isRemembered, "restoring writes nothing back")
    // The whole point of the case: About Pharos must not become the pane ⌘,
    // opens next time.
    expectTrue(!SettingsNavigationSource.deepLink.isRemembered, "a deep link is NOT remembered")
}

func runTests() {
    testHistory()
    testPrefs()
    testRegistry()
    testNavigationSources()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
