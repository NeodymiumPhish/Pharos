// Standalone test for DurationText — no Xcode project involvement. Compiled
// by scripts/test-duration-text.sh.
//
// What this suite is FOR: the four tiers (ms, s, m[+s], h[+m]) must keep the
// exact boundaries and composition the legacy ResultsGridVC.formatDuration /
// QueryNotifier.formatDuration bodies used — only the number itself becomes
// locale-aware. A regression here would either shift a threshold (a 59.9s
// query suddenly reading "1m 0s") or hard-code "." again, which is the whole
// point of the change.
import Foundation

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private let enUS = Locale(identifier: "en_US")
private let deDE = Locale(identifier: "de_DE")

private func testMillisecondsTier() {
    expect(DurationText.short(milliseconds: 850, locale: enUS), "850 ms", "below 1 s shows whole milliseconds")
}

private func testSecondsTierOneDecimal() {
    expect(DurationText.short(milliseconds: 1200, locale: enUS), "1.2 s", "below 60 s shows one decimal (en_US)")
    expect(DurationText.short(milliseconds: 1200, locale: deDE), "1,2 s", "below 60 s uses the locale's decimal separator (de_DE)")
}

private func testMinutesTier() {
    expect(DurationText.short(milliseconds: 65_000, locale: enUS), "1m 5s", "65 s composes as minutes + seconds")
}

private func testHoursTier() {
    expect(DurationText.short(milliseconds: 3_661_000, locale: enUS), "1h 1m", "one hour and a minute composes as hours + minutes")
}

/// A minutes-tier value with no leftover seconds drops the seconds term
/// entirely, same as the legacy body (`seconds >= 0.5` guard).
private func testMinutesTierExactWholeMinuteDropsSeconds() {
    expect(DurationText.short(milliseconds: 120_000, locale: enUS), "2m", "an exact whole minute has no seconds term")
}

/// An hours-tier value with no leftover minutes drops the minutes term.
private func testHoursTierExactWholeHourDropsMinutes() {
    expect(DurationText.short(milliseconds: 3_600_000, locale: enUS), "1h", "an exact whole hour has no minutes term")
}

func runTests() {
    testMillisecondsTier()
    testSecondsTierOneDecimal()
    testMinutesTier()
    testHoursTier()
    testMinutesTierExactWholeMinuteDropsSeconds()
    testHoursTierExactWholeHourDropsMinutes()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
