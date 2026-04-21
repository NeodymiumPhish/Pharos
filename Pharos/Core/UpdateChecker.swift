import AppKit
import Foundation

/// Polls GitHub for newer stable releases of Pharos and posts a macOS
/// notification (via `QueryNotifier.postUpdateAvailableNotification`) when a
/// newer version is available.
///
/// Behavior:
/// - Fires one check at launch and schedules a 6-hour repeating timer.
/// - Skips the HTTP call if `settings.checkForUpdates` is false.
/// - Rate-limits the HTTP call to at most once per 24 hours (via UserDefaults).
/// - Posts at most one notification per unique new version (per-version dedupe).
/// - Silently ignores network / decode / version-parse failures; only successful
///   calls update the `lastCheckedAt` timestamp.
final class UpdateChecker {

    static let shared = UpdateChecker()

    private static let apiURL = URL(string: "https://api.github.com/repos/NeodymiumPhish/Pharos/releases/latest")!
    private static let checkIntervalSeconds: TimeInterval = 6 * 3600
    private static let httpCacheSeconds: TimeInterval = 24 * 3600
    private static let requestTimeoutSeconds: TimeInterval = 10

    private static let lastCheckedAtKey = "updateCheckerLastCheckedAt"
    private static let lastNotifiedVersionKey = "updateCheckerLastNotifiedVersion"

    private var timer: Timer?

    private init() {}

    /// Start the periodic check. Safe to call multiple times (no-ops if already started).
    func start() {
        guard timer == nil else { return }
        Task { await checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkIntervalSeconds, repeats: true) { _ in
            Task { await UpdateChecker.shared.checkNow() }
        }
    }

    /// Run one check now, respecting the settings toggle and 24h rate limit.
    func checkNow() async {
        let settings = await MainActor.run { AppStateManager.shared.settings }
        guard settings.checkForUpdates else { return }

        if let lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedAtKey) as? Date,
           Date().timeIntervalSince(lastCheckedAt) < Self.httpCacheSeconds {
            NSLog("[UpdateChecker] Rate-limited (last check < 24h ago); skipping HTTP.")
            return
        }

        let latest: GitHubRelease
        do {
            latest = try await fetchLatestRelease()
        } catch {
            NSLog("[UpdateChecker] fetch failed: \(error)")
            return
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckedAtKey)

        // Normalize the tag_name to avoid discrepancies between the identifier
        // used for per-version dedupe and the one used for the notification
        // request identifier.
        let normalizedTag = latest.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTag.isEmpty else {
            NSLog("[UpdateChecker] empty tag_name after normalization; skipping.")
            return
        }

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        guard let currentComponents = Self.parseVersion(currentVersion),
              let latestComponents = Self.parseVersion(normalizedTag) else {
            NSLog("[UpdateChecker] could not parse current=\(currentVersion) or latest=\(normalizedTag); skipping.")
            return
        }
        guard currentComponents.lexicographicallyPrecedes(latestComponents) else { return }

        let lastNotified = UserDefaults.standard.string(forKey: Self.lastNotifiedVersionKey)
        guard lastNotified != normalizedTag else {
            NSLog("[UpdateChecker] Already notified for \(normalizedTag); skipping.")
            return
        }

        QueryNotifier.shared.postUpdateAvailableNotification(
            newVersion: normalizedTag,
            currentVersion: currentVersion,
            releasesUrl: latest.html_url
        )
        UserDefaults.standard.set(normalizedTag, forKey: Self.lastNotifiedVersionKey)
    }

    // MARK: - HTTP

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.apiURL, timeoutInterval: Self.requestTimeoutSeconds)
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        request.setValue("Pharos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "UpdateChecker", code: status, userInfo: [NSLocalizedDescriptionKey: "Non-2xx response: \(status)"])
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Version parsing

    /// Parse a version string (with optional leading 'v' or 'V') into a 3-element `[major, minor, patch]`.
    /// Returns nil if parsing fails for any segment.
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = raw
        if let first = s.first, first == "v" || first == "V" {
            s = String(s.dropFirst())
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
}
