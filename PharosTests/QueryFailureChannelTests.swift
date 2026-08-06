// Standalone test runner for QueryFailureChannel. Not part of the app target —
// compiled with the implementation by scripts/test-query-failure-channel.sh.
import Foundation

var failures = 0

func expect(
    _ actual: QueryFailureChannel, _ expected: QueryFailureChannel, _ name: String
) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    expect(QueryFailureChannel.choose(
        appInactive: false, isBackgroundTab: true,
        notifyWhenAppInactive: true, notifyWhenBackgroundTab: true
    ), .inAppBanner, "app in front, background tab → a banner inside the window")

    expect(QueryFailureChannel.choose(
        appInactive: true, isBackgroundTab: false,
        notifyWhenAppInactive: true, notifyWhenBackgroundTab: true
    ), .systemBanner, "app behind → a system banner, because a Toast is invisible")

    expect(QueryFailureChannel.choose(
        appInactive: true, isBackgroundTab: true,
        notifyWhenAppInactive: true, notifyWhenBackgroundTab: true
    ), .systemBanner, "app behind wins over the tab state")

    expect(QueryFailureChannel.choose(
        appInactive: false, isBackgroundTab: false,
        notifyWhenAppInactive: true, notifyWhenBackgroundTab: true
    ), QueryFailureChannel.none, "the tab in front of the user gets no banner — the sheet is open")

    expect(QueryFailureChannel.choose(
        appInactive: false, isBackgroundTab: true,
        notifyWhenAppInactive: true, notifyWhenBackgroundTab: false
    ), QueryFailureChannel.none, "the background-tab setting can turn the banner off")

    expect(QueryFailureChannel.choose(
        appInactive: true, isBackgroundTab: false,
        notifyWhenAppInactive: false, notifyWhenBackgroundTab: true
    ), QueryFailureChannel.none, "the app-inactive setting can turn the banner off")

    expect(QueryFailureChannel.choose(
        appInactive: true, isBackgroundTab: true,
        notifyWhenAppInactive: false, notifyWhenBackgroundTab: true
    ), .systemBanner, "one allowing setting is enough, and the channel still follows app state")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
