// Standalone test runner for the pure parts of the update check: how a
// version tag is parsed, which release the pre-release channel picks, and
// what each frequency asks of the timer and the rate limit.
//
// Compiled by scripts/test-update-check-policy.sh with Settings.swift, so
// the enums under test are the ones that cross the FFI.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func testVersionParsing() {
    expectEqual(UpdateCheckPolicy.parseVersion("1.2.3"), [1, 2, 3], "a plain version parses")
    expectEqual(UpdateCheckPolicy.parseVersion("v1.2.3"), [1, 2, 3], "a leading v is dropped")
    expectEqual(UpdateCheckPolicy.parseVersion("V10.0.42"), [10, 0, 42], "a leading V is dropped")
    // The change this suite exists for: the pre-release channel must be able
    // to compare a beta tag, which the old parser rejected outright.
    expectEqual(UpdateCheckPolicy.parseVersion("1.2.3-beta.1"), [1, 2, 3], "a pre-release suffix is dropped, not rejected")
    expectEqual(UpdateCheckPolicy.parseVersion("v2.0.0-rc.2"), [2, 0, 0], "a release-candidate suffix too")
    expectEqual(UpdateCheckPolicy.parseVersion("1.2.3+build.5"), [1, 2, 3], "build metadata is dropped")
    expectEqual(UpdateCheckPolicy.parseVersion(" 1.2.3 "), [1, 2, 3], "surrounding space is ignored")
    expectEqual(UpdateCheckPolicy.parseVersion("1.2"), nil, "two segments are not a version")
    expectEqual(UpdateCheckPolicy.parseVersion("nightly"), nil, "a word is not a version")
    expectEqual(UpdateCheckPolicy.parseVersion("1.x.3"), nil, "a non-numeric segment is not a version")

    // Ordering is what the caller actually asks of it.
    expectEqual(UpdateCheckPolicy.isNewer("1.4.1", than: "1.4.0"), true, "1.4.1 is newer than 1.4.0")
    expectEqual(UpdateCheckPolicy.isNewer("1.4.0-beta.9", than: "1.4.0"), false, "a beta of the SAME version is not newer")
    expectEqual(UpdateCheckPolicy.isNewer("1.5.0-beta.1", than: "1.4.9"), true, "a beta of a LATER version is newer")
    expectEqual(UpdateCheckPolicy.isNewer("nightly", than: "1.4.0"), false, "an unreadable tag is never newer")
    expectEqual(UpdateCheckPolicy.isNewer("1.4.1", than: "rubbish"), false, "an unreadable current version never triggers")
}

private func release(_ tag: String, prerelease: Bool, draft: Bool) -> UpdateCheckPolicy.Release {
    let json = """
    {"tag_name":"\(tag)","html_url":"https://example.invalid/\(tag)","prerelease":\(prerelease),"draft":\(draft)}
    """
    return try! JSONDecoder().decode(UpdateCheckPolicy.Release.self, from: Data(json.utf8))
}

private func testPreReleaseChoice() {
    let feed = [
        release("1.5.0-rc.1", prerelease: true, draft: true),
        release("1.4.9-beta.3", prerelease: true, draft: false),
        release("1.4.8", prerelease: false, draft: false),
        release("1.4.7-beta.1", prerelease: true, draft: false),
    ]
    expectEqual(UpdateCheckPolicy.newestPreRelease(in: feed)?.tag_name, "1.4.9-beta.3",
                "the newest non-draft pre-release wins, and the draft above it is skipped")
    expectEqual(UpdateCheckPolicy.newestPreRelease(in: [release("1.4.8", prerelease: false, draft: false)])?.tag_name, nil,
                "a feed of stable releases has no pre-release")
    expectEqual(UpdateCheckPolicy.newestPreRelease(in: [])?.tag_name, nil, "an empty feed has no pre-release")

    // A decoded release without the two flags (an older API shape) is stable.
    let bare = try! JSONDecoder().decode(
        UpdateCheckPolicy.Release.self,
        from: Data(#"{"tag_name":"1.0.0","html_url":"https://example.invalid/1"}"#.utf8))
    expectEqual(bare.prerelease, false, "a missing prerelease flag decodes as false")
    expectEqual(bare.draft, false, "a missing draft flag decodes as false")
}

private func testFrequency() {
    expectEqual(UpdateFrequency.onLaunch.repeatInterval, nil, "on-launch schedules no repeating timer")
    expectEqual(UpdateFrequency.daily.repeatInterval, 24 * 3600, "daily repeats every 24 hours")
    expectEqual(UpdateFrequency.weekly.repeatInterval, 7 * 24 * 3600, "weekly repeats every 7 days")
    expectEqual(UpdateFrequency.onLaunch.cacheSeconds, 24 * 3600, "on-launch still rate-limits to a day")
    expectEqual(UpdateFrequency.weekly.cacheSeconds, 7 * 24 * 3600, "weekly rate-limits to a week")
    expectEqual(UpdateFrequency.allCases.count, 3, "three frequencies are offered")
    expectEqual(AppSettings().updates.checkFrequency, .daily, "the default frequency is daily")
    expectEqual(AppSettings().updates.channel, .stable, "the default channel is stable")
    expectEqual(AppSettings().results.nullStyle, .italic, "the default NULL style is the italic one the grid always had")
}

func runTests() {
    testVersionParsing()
    testPreReleaseChoice()
    testFrequency()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
