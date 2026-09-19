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
    }
}
