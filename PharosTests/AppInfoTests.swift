// Standalone tests for AppInfo — the version strings Settings ▸ About shows
// and the three web addresses Pharos opens. Compiled by
// scripts/test-app-info.sh. No bundle, no AppKit: every string is read from a
// dictionary the test supplies, which is why the type takes one.
import Foundation

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

/// The keys Pharos's own Info.plist carries.
private let shipping: [String: Any] = [
    "CFBundleDisplayName": "Pharos",
    "CFBundleName": "Pharos",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
]

private func testVersionStrings() {
    expectEqual(AppInfo.version(from: shipping), "0.1.0", "the marketing version is read")

    // The marketing version ALONE. The release workflow sets CFBundleVersion
    // to the same string as CFBundleShortVersionString, so a parenthetical
    // build number only repeated the line ("Version 2.6.205 (2.6.205)").
    expectEqual(AppInfo.versionLine(from: shipping), "Version 0.1.0",
                "the build number is not appended")
    expectEqual(AppInfo.versionLine(from: ["CFBundleVersion": "77"]),
                "Version 0.0.0", "a build number alone adds nothing")

    // A build with no version must still produce a line. The fallback is the
    // one UpdateChecker uses, so an unversioned build reads as older than
    // every release instead of crashing the pane.
    expectEqual(AppInfo.version(from: [:]), "0.0.0", "no version key → 0.0.0")
    expectEqual(AppInfo.versionLine(from: [:]), "Version 0.0.0", "no keys → the fallback line")

    expectEqual(AppInfo.versionLine(from: ["CFBundleShortVersionString": "2.3.4"]),
                "Version 2.3.4", "the version stands alone")

    // A pre-release tag is part of the string, not something to strip: that
    // is UpdateCheckPolicy's job, and About reports what the build says.
    expectEqual(AppInfo.versionLine(from: ["CFBundleShortVersionString": "0.2.0-beta.1",
                                           "CFBundleVersion": "12"]),
                "Version 0.2.0-beta.1", "a pre-release version is shown as it is")

    // A number written as a number rather than a string is not a String and
    // must not become "Optional(2)" on screen.
    expectEqual(AppInfo.versionLine(from: ["CFBundleShortVersionString": 2]),
                "Version 0.0.0", "a non-string version value is ignored, not interpolated")
}

private func testName() {
    expectEqual(AppInfo.name(from: shipping), "Pharos", "the display name is read")
    expectEqual(AppInfo.name(from: ["CFBundleName": "Fyros"]), "Fyros",
                "CFBundleName serves when there is no display name")
    expectEqual(AppInfo.name(from: ["CFBundleDisplayName": "Localised",
                                    "CFBundleName": "Pharos"]), "Localised",
                "the display name wins, because that is the localised one")
    expectEqual(AppInfo.name(from: [:]), "Pharos", "no keys → Pharos")
}

private func testURLs() {
    let urls = [("repository", AppInfo.repositoryURL),
                ("help", AppInfo.helpURL),
                ("keyboard shortcuts", AppInfo.keyboardShortcutsURL),
                ("release notes", AppInfo.releaseNotesURL)]
    for (label, url) in urls {
        expectEqual(url.scheme, "https", "the \(label) address is https")
        expectTrue(!(url.host ?? "").isEmpty, "the \(label) address has a host")
    }
    expectEqual(AppInfo.repositoryURL.host, "github.com", "the repository is on GitHub")
    expectEqual(AppInfo.repositoryURL.path, "/NeodymiumPhish/Pharos", "the repository path")
    expectEqual(AppInfo.releaseNotesURL.path, "/NeodymiumPhish/Pharos/releases",
                "the release notes are that repository's releases")
    expectEqual(AppInfo.helpURL.host, "neodymiumphish.github.io", "the help site")
    expectTrue(AppInfo.keyboardShortcutsURL.absoluteString.hasPrefix(AppInfo.helpURL.absoluteString),
               "the shortcut reference is a page of the help site")

    // The caption in the About pane is the repository address without its
    // scheme; it must not drift from the URL the button opens.
    expectEqual(AppInfo.repositoryLabel,
                (AppInfo.repositoryURL.host ?? "") + AppInfo.repositoryURL.path,
                "the short label matches the address it stands for")
}

func runTests() {
    testVersionStrings()
    testName()
    testURLs()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
