import Foundation

/// The parts of the update check that are pure decisions, split out from
/// `UpdateChecker` so `scripts/test-update-check-policy.sh` can compile them
/// with no AppKit, no FFI and no network: what a version tag means, and which
/// release a channel wants.
enum UpdateCheckPolicy {

    /// One release as the GitHub API describes it.
    struct Release: Decodable, Equatable {
        let tag_name: String
        let html_url: String
        /// A release that does not say it is a pre-release is a stable one.
        let prerelease: Bool
        let draft: Bool

        /// Hand-written, because Swift's synthesized decoder does NOT fall
        /// back to a property's default value for a missing key — it throws.
        /// The `/releases/latest` payload has both flags, but a hand-made
        /// fixture or an older shape may not, and one missing flag must not
        /// lose the whole answer.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag_name = try c.decode(String.self, forKey: .tag_name)
            html_url = try c.decode(String.self, forKey: .html_url)
            prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case tag_name, html_url, prerelease, draft
        }
    }

    /// Parse a version string (with an optional leading `v` or `V`) into
    /// `[major, minor, patch]`. Returns nil when any of the three is missing
    /// or is not a number.
    ///
    /// A pre-release suffix is DROPPED, not rejected: `"1.2.3-beta.1"` parses
    /// as `[1, 2, 3]`, because the pre-release channel has to compare those
    /// tags and the old parser refused them outright. Comparing only the
    /// three numbers means `1.2.3-beta.1` and `1.2.3` rank equal, which is
    /// the right answer to "is there something newer than what I run".
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" {
            s = String(s.dropFirst())
        }
        // Everything from the first `-` or `+` is pre-release or build metadata.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[s.startIndex..<cut])
        }
        let parts = s.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var result: [Int] = []
        for i in 0..<3 {
            guard let n = Int(parts[i]) else { return nil }
            result.append(n)
        }
        return result
    }

    /// The release the pre-release channel wants: the newest entry that is
    /// marked pre-release and is not a draft. GitHub returns newest first.
    static func newestPreRelease(in releases: [Release]) -> Release? {
        releases.first { $0.prerelease && !$0.draft }
    }

    /// Whether `latest` is newer than `current`. False when either cannot be
    /// parsed, so an unreadable tag never raises a notification.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let currentParts = parseVersion(current), let latestParts = parseVersion(latest) else { return false }
        return currentParts.lexicographicallyPrecedes(latestParts)
    }
}
