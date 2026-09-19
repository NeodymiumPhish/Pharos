import AppKit
import Combine
import Foundation
import os

/// Polls GitHub for newer stable releases of Pharos and posts a macOS
/// notification (via `QueryNotifier.postUpdateAvailableNotification`) when a
/// newer version is available.
///
/// Behavior:
/// - Fires one check at launch, then repeats at the period the user chose
///   (Settings ▸ General ▸ Updates): daily, weekly, or not at all.
/// - Skips the HTTP call if `settings.checkForUpdates` is false.
/// - Rate-limits the HTTP call to at most once per that same period, so a
///   long-running session does not hammer GitHub. The launch check and the
///   pane's Check Now button bypass the limit.
/// - Looks at the latest stable release, or at the newest pre-release when
///   the user chose that channel.
/// - Posts at most one notification per unique new version (per-version dedupe).
/// - Silently ignores network / decode / version-parse failures; only successful
///   calls update the `lastCheckedAt` timestamp.
final class UpdateChecker {

    static let shared = UpdateChecker()

    private static let latestURL = URL(string: "https://api.github.com/repos/NeodymiumPhish/Pharos/releases/latest")!
    /// The pre-release channel has no "latest" endpoint: the newest release
    /// that is marked pre-release and not a draft is the answer, and ten is
    /// far more than enough to find it.
    private static let recentURL = URL(string: "https://api.github.com/repos/NeodymiumPhish/Pharos/releases?per_page=10")!
    private static let requestTimeoutSeconds: TimeInterval = 10

    static let lastCheckedAtKey = "updateCheckerLastCheckedAt"
    private static let lastNotifiedVersionKey = "updateCheckerLastNotifiedVersion"

    private var timer: Timer?
    private var frequencyCancellable: AnyCancellable?

    /// What one check did, for the Settings pane's caption.
    enum Outcome: Equatable {
        case turnedOff
        case rateLimited
        case failed(String)
        case upToDate(current: String)
        case updateAvailable(version: String)

        var message: String {
            switch self {
            case .turnedOff:
                return String(localized: "Update checks are turned off.")
            case .rateLimited:
                return String(localized: "Checked recently.")
            case .failed(let reason):
                return String(localized: "Could not check: \(reason)")
            case .upToDate(let current):
                return String(localized: "Pharos \(current) is the newest version.")
            case .updateAvailable(let version):
                return String(localized: "Pharos \(version) is available.")
            }
        }
    }

    /// When the last successful check ran, for the pane's caption.
    var lastCheckedAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastCheckedAtKey) as? Date
    }

    private init() {}

    /// Start the periodic check. Safe to call multiple times (no-ops if already started).
    /// `@MainActor` compile-time-enforces attaching the Timer to the main run loop;
    /// attaching to a background thread's run loop would silently never fire.
    ///
    /// The launch check bypasses the rate-limit cache so users see a newly
    /// published release on every restart. Periodic ticks still respect it.
    @MainActor
    func start() {
        guard frequencyCancellable == nil else { return }
        Task { _ = await checkNow(force: true) }
        restartTimer()
        // A change of frequency takes effect at once, not at the next launch.
        frequencyCancellable = AppStateManager.shared.$settings
            .map(\.updates.checkFrequency)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restartTimer() }
    }

    /// Put the repeating timer on the period the user chose. Called by
    /// `start()` and again whenever the frequency changes, so a change takes
    /// effect without a relaunch. `onLaunch` leaves no timer at all.
    @MainActor
    func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let interval = AppStateManager.shared.settings.updates.checkFrequency.repeatInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { _ = await UpdateChecker.shared.checkNow() }
        }
    }

    /// Run one check now.
    /// - Parameter force: if true, bypass the rate-limit cache. The user's
    ///   `checkForUpdates` preference gate is still respected.
    @discardableResult
    func checkNow(force: Bool = false) async -> Outcome {
        let settings = await MainActor.run { AppStateManager.shared.settings }
        guard settings.checkForUpdates else { return .turnedOff }

        let cacheSeconds = settings.updates.checkFrequency.cacheSeconds
        if !force,
           let lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedAtKey) as? Date,
           Date().timeIntervalSince(lastCheckedAt) < cacheSeconds {
            Log.updates.info("Rate-limited (last check inside the chosen period); skipping HTTP.")
            return .rateLimited
        }

        let latest: UpdateCheckPolicy.Release
        do {
            latest = try await fetchRelease(channel: settings.updates.channel)
        } catch {
            Log.updates.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckedAtKey)

        // Normalize the tag_name to avoid discrepancies between the identifier
        // used for per-version dedupe and the one used for the notification
        // request identifier.
        let normalizedTag = latest.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTag.isEmpty else {
            Log.updates.warning("empty tag_name after normalization; skipping.")
            return .failed(String(localized: "the release has no version"))
        }

        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        guard UpdateCheckPolicy.parseVersion(normalizedTag) != nil,
              UpdateCheckPolicy.parseVersion(currentVersion) != nil else {
            Log.updates.warning("could not parse current=\(currentVersion, privacy: .public) or latest=\(normalizedTag, privacy: .public); skipping.")
            return .failed(String(localized: "the version could not be read"))
        }
        guard UpdateCheckPolicy.isNewer(normalizedTag, than: currentVersion) else {
            return .upToDate(current: currentVersion)
        }

        let lastNotified = UserDefaults.standard.string(forKey: Self.lastNotifiedVersionKey)
        guard lastNotified != normalizedTag else {
            Log.updates.info("Already notified for \(normalizedTag, privacy: .public); skipping.")
            return .updateAvailable(version: normalizedTag)
        }

        QueryNotifier.shared.postUpdateAvailableNotification(
            newVersion: normalizedTag,
            currentVersion: currentVersion,
            releasesUrl: latest.html_url
        )
        UserDefaults.standard.set(normalizedTag, forKey: Self.lastNotifiedVersionKey)
        return .updateAvailable(version: normalizedTag)
    }

    // MARK: - HTTP

    /// The release this channel cares about. Stable asks GitHub for its own
    /// idea of "latest"; pre-release takes the newest release that is marked
    /// pre-release and is not a draft.
    private func fetchRelease(channel: UpdateChannel) async throws -> UpdateCheckPolicy.Release {
        switch channel {
        case .stable:
            return try await fetch(Self.latestURL, as: UpdateCheckPolicy.Release.self)
        case .preRelease:
            let recent = try await fetch(Self.recentURL, as: [UpdateCheckPolicy.Release].self)
            guard let newest = UpdateCheckPolicy.newestPreRelease(in: recent) else {
                throw NSError(domain: "UpdateChecker", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "no pre-release was found")])
            }
            return newest
        }
    }

    private func fetch<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        request.setValue("Pharos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "UpdateChecker", code: status, userInfo: [NSLocalizedDescriptionKey: "Non-2xx response: \(status)"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

}
