// Standalone test runner for SettingsMigration — the one-way move of the
// preferences that predate the Settings window out of UserDefaults and into
// AppSettings. Not part of the app target; compiled together with the
// implementation by scripts/test-settings-migration.sh.
//
// The whole design rests on one thing: the PRESENCE of the key is the "not
// migrated yet" signal. A migration that copies but does not remove runs on
// every launch and puts the old value back over the user's new choice, which
// is invisible until somebody changes the setting and watches it revert. Half
// of what is below exists to pin that.
//
// A per-run suite name keeps this off the real defaults and lets two sweeps
// run at once without clobbering each other.
import Foundation

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

private let copyKey = SettingsMigration.copyIncludeHeadersKey
private let panelKey = SettingsMigration.resultTabsPanelVisibleKey

func runTests() {
    let suiteName = "pharos.settings-migration.\(getpid()).\(UInt32.random(in: 0..<UInt32.max))"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        print("FAIL could not open a test defaults suite")
        exit(1)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    func clear() {
        defaults.removeObject(forKey: copyKey)
        defaults.removeObject(forKey: panelKey)
    }

    // MARK: - Nothing stored: nothing happens

    clear()
    var settings = AppSettings()
    expectFalse(SettingsMigration.migrate(from: defaults, into: &settings),
                "absent keys report no change")
    expectTrue(settings == AppSettings(), "absent keys leave the settings exactly as they were")

    // MARK: - The value is copied across

    clear()
    settings = AppSettings()
    defaults.set(false, forKey: copyKey)
    expectTrue(SettingsMigration.migrate(from: defaults, into: &settings), "a stored value reports a change")
    expectFalse(settings.results.copyIncludeHeaders, "PharosCopyIncludeHeaders lands on results.copyIncludeHeaders")
    expectTrue(settings.results.showResultTabsPanelByDefault,
               "the other field is untouched when only one key is stored")

    clear()
    settings = AppSettings()
    defaults.set(false, forKey: panelKey)
    expectTrue(SettingsMigration.migrate(from: defaults, into: &settings), "the panel key reports a change too")
    expectFalse(settings.results.showResultTabsPanelByDefault,
                "ResultTabsPanelVisibleByDefault lands on results.showResultTabsPanelByDefault")

    // A stored `true` must move as well, even though it equals the default —
    // the key's presence is the signal, not the value's novelty. Otherwise the
    // key would sit there for ever and migrate again after any later change.
    clear()
    settings = AppSettings()
    settings.results.copyIncludeHeaders = false
    defaults.set(true, forKey: copyKey)
    expectTrue(SettingsMigration.migrate(from: defaults, into: &settings), "a stored true migrates too")
    expectTrue(settings.results.copyIncludeHeaders, "a stored true overwrites a false in the model")

    // Both at once.
    clear()
    settings = AppSettings()
    defaults.set(false, forKey: copyKey)
    defaults.set(false, forKey: panelKey)
    expectTrue(SettingsMigration.migrate(from: defaults, into: &settings), "both keys report a change")
    expectFalse(settings.results.copyIncludeHeaders, "both keys: headers moved")
    expectFalse(settings.results.showResultTabsPanelByDefault, "both keys: panel moved")

    // MARK: - The keys are removed afterwards

    expectTrue(defaults.object(forKey: copyKey) == nil, "PharosCopyIncludeHeaders is removed after migrating")
    expectTrue(defaults.object(forKey: panelKey) == nil,
               "ResultTabsPanelVisibleByDefault is removed after migrating")

    // MARK: - A second run is a no-op

    // This is the one that matters. The user's own later choice must survive
    // the next launch.
    settings.results.copyIncludeHeaders = true
    settings.results.showResultTabsPanelByDefault = true
    let before = settings
    expectFalse(SettingsMigration.migrate(from: defaults, into: &settings),
                "a second migrate reports no change")
    expectTrue(settings == before, "a second migrate does not touch the user's later choice")

    // MARK: - A value of the wrong type

    // A hand-edited plist, or a key another build once used differently. It
    // must not crash and must not force a wrong default.
    clear()
    settings = AppSettings()
    defaults.set(["not": "a bool"], forKey: copyKey)
    defaults.set("neither is this", forKey: panelKey)
    let survived = SettingsMigration.migrate(from: defaults, into: &settings)
    expectFalse(survived, "a value of the wrong type is not migrated")
    expectTrue(settings == AppSettings(), "a value of the wrong type leaves the settings alone")

    // A number IS readable as a bool — that is how a plist stores one — so 0
    // and 1 still migrate rather than being thrown away.
    clear()
    settings = AppSettings()
    defaults.set(0, forKey: copyKey)
    expectTrue(SettingsMigration.migrate(from: defaults, into: &settings), "a stored 0 migrates")
    expectFalse(settings.results.copyIncludeHeaders, "a stored 0 reads as false")

    clear()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
