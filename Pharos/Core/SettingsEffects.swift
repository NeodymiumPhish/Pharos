import AppKit
import Combine

/// Applies the settings that DO something rather than describe something.
///
/// The Settings window has no Save button, so a switch the user clears has to
/// take effect while they watch — no relaunch, and no pane reaching out to
/// start and stop services on its own. Each effect below follows the STORED
/// value, exactly as `ThemeApplier` follows the theme: one subscriber per
/// effect, one place that owns the service, and launch is the same code path
/// as a change, because the publisher delivers the current value the moment
/// `start()` subscribes.
///
/// Settings that are only READ where they are used — the results grid's
/// density, the editor's tab size — do not belong here. This object is for the
/// ones with a running thing behind them.
@MainActor
final class SettingsEffects {

    static let shared = SettingsEffects()

    private var cancellables: Set<AnyCancellable> = []

    /// The sleep observer, held only while the setting behind it is on. It is
    /// on `NSWorkspace.shared.notificationCenter`, not the default one — the
    /// workspace notifications are not posted to the default centre.
    private var sleepObserver: NSObjectProtocol?

    private init() {}

    /// Apply every effect now, and on every change from here on.
    ///
    /// Call once, from `applicationDidFinishLaunching`, AFTER `pharos_init`
    /// and `loadSettings()`: the Spotlight effect reads the saved queries out
    /// of the core.
    func start() {
        let settings = AppStateManager.shared.$settings

        // The session autosave interval. `dropFirst` because the timer is
        // started by the launch path with the stored value already in it;
        // this only has to follow LATER changes.
        settings
            .map(\.session.autosaveIntervalSeconds)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in AppStateManager.shared.restartSessionAutosave() }
            .store(in: &cancellables)

        // Toast duration. `Toast` never reaches for the settings itself — it
        // compiles standalone in `scripts/test-toast-click.sh` — so the value
        // is pushed at it instead.
        settings
            .map(\.notifications.toastDuration)
            .removeDuplicates()
            .sink { Toast.defaultDuration = $0.seconds }
            .store(in: &cancellables)

        // Spotlight. On starts the indexer (which indexes once and follows
        // every later change); off takes everything this app put in Spotlight
        // back out, so clearing the switch is a removal and not merely a stop.
        settings
            .map(\.security.indexSavedQueriesInSpotlight)
            .removeDuplicates()
            .sink { indexing in
                if indexing {
                    SavedQuerySpotlightIndexer.shared.start()
                } else {
                    Task { await SavedQuerySpotlightIndexer.shared.stop() }
                }
            }
            .store(in: &cancellables)

        // The engine's log level. `pharos_init` caps the core at "warn" —
        // what it has always written — and this raises or lowers it from
        // there. No `dropFirst`: the launch delivery is what applies the
        // stored level, and the call is idempotent.
        //
        // The engine refuses the call outright while RUST_LOG is set in the
        // environment, so a developer who names a level in their shell keeps
        // it whatever this pane says.
        settings
            .map(\.diagnostics.logLevel)
            .removeDuplicates()
            .sink { PharosCore.setLogLevel($0) }
            .store(in: &cancellables)

        // MetricKit. Both calls are idempotent, so the launch delivery and a
        // change are the same call.
        settings
            .map(\.security.collectPerformanceMetrics)
            .removeDuplicates()
            .sink { collecting in
                if collecting { Diagnostics.start() } else { Diagnostics.stop() }
            }
            .store(in: &cancellables)

        // Forget typed passwords on sleep. The observer exists only while the
        // switch is on, so the off state costs nothing and cannot fire.
        settings
            .map(\.security.clearPasswordCacheOnSleep)
            .removeDuplicates()
            .sink { [weak self] clearing in
                self?.observeSleep(clearing)
            }
            .store(in: &cancellables)
    }

    /// Start or stop listening for sleep.
    ///
    /// The handler clears the core's PROCESS-ONLY secret map and nothing else:
    /// the Keychain is untouched, so a connection that remembers its password
    /// is unaffected and wakes up able to connect. That one map holds BOTH
    /// kinds of typed secret — database passwords under the connection id, SSH
    /// tunnel secrets under `<id>/ssh` — so a tunnel that remembers nothing is
    /// asked for its secret again after sleep, exactly as the password is.
    /// Only the count is logged — a secret, or the name of the connection it
    /// belongs to, never reaches the log.
    private func observeSleep(_ clearing: Bool) {
        let centre = NSWorkspace.shared.notificationCenter
        if let observer = sleepObserver {
            centre.removeObserver(observer)
            sleepObserver = nil
        }
        guard clearing else { return }
        sleepObserver = centre.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            let dropped = PharosCore.clearSessionPasswords()
            // The front end's own record of which connections have one, in the
            // same breath. If the two drifted apart, the next failure would be
            // read as "it has a password" and dial straight back into it
            // instead of asking.
            PasswordPromptCoordinator.shared.forgetSessionPasswords()
            guard dropped > 0 else { return }
            // The proof that the owner was present goes with the passwords:
            // keeping it would let the next connect skip the gate on a Mac
            // that has just been asleep.
            AppStateManager.shared.forgetGatePasses()
            Log.state.info("Sleep: forgot \(dropped, privacy: .public) typed secret(s)")
        }
    }
}
