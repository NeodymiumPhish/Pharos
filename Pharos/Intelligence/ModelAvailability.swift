import AppKit
import Combine
import FoundationModels

/// Whether the on-device Apple Intelligence features may be offered.
///
/// Two questions, answered as one. The model itself has to be usable on this
/// Mac — the hardware must be eligible, the user must have turned Apple
/// Intelligence on in System Settings, and the assets must have finished
/// downloading — and the user must not have turned the features off in
/// Pharos. `isAvailable` is true only when both hold.
///
/// Both answers can change while the app is running: the user can switch Apple
/// Intelligence on in System Settings without quitting Pharos, so the system
/// side is re-read every time the app becomes active, and the Pharos side
/// follows `AppStateManager`'s published settings.
///
/// Every feature asks this object before it opens a session. Nothing here
/// sends anything anywhere: `SystemLanguageModel` runs on this Mac.
@MainActor
final class ModelAvailability: ObservableObject {

    static let shared = ModelAvailability()

    /// Test seam, the same idea as `AccessibilityDisplay.overrideForTesting`:
    /// force the answer without a real model and without touching the stored
    /// settings. Production code never sets it.
    ///
    /// Forced OFF reports the settings reason, because that is the same thing
    /// the user would see had they cleared the checkbox — a forced refusal is
    /// never a claim about the hardware.
    static var overrideForTesting: Bool? {
        didSet { shared.refresh() }
    }

    /// True only when the model is usable AND the Pharos setting is on.
    @Published private(set) var isAvailable: Bool = false

    /// Why not, in one sentence for the user. Nil when `isAvailable` is true.
    @Published private(set) var unavailableReason: String?

    /// Whether the MODEL is usable, ignoring the Pharos setting.
    ///
    /// Settings ▸ Intelligence needs this on its own: a switch that the user
    /// cleared must stay clickable so they can set it again, while a Mac that
    /// cannot run the model disables it outright. Features want `isAvailable`.
    @Published private(set) var systemModelIsAvailable: Bool = false

    /// "Use Apple Intelligence features", as last PUBLISHED.
    ///
    /// Cached, not re-read. `@Published` notifies its subscribers on `willSet`,
    /// so a sink that reaches back for `AppStateManager.shared.settings` reads
    /// the value the user has just replaced — the switch would appear to take
    /// one change to take effect. The delivered value is the only correct one
    /// at that moment, and every later reader wants the same value.
    private var enabledInSettings = true

    private var settingsCancellable: AnyCancellable?
    private var activeObserver: NSObjectProtocol?

    private init() {
        // The publisher delivers the current value on subscribe, so this also
        // seeds `enabledInSettings` — one code path for launch and change, as
        // `ThemeApplier` does it.
        settingsCancellable = AppStateManager.shared.$settings
            .map(\.useAppleIntelligence)
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.enabledInSettings = enabled
                self?.refresh()
            }

        // System Settings ▸ Apple Intelligence & Siri is a different app, so
        // there is no notification to observe. Becoming active again is the
        // first moment the change can matter here.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    /// Re-read both sides and republish. Cheap, and safe to call at any time.
    func refresh() {
        let wasAvailable = isAvailable
        defer {
            if isAvailable != wasAvailable {
                Log.intelligence.info(
                    "Apple Intelligence \(self.isAvailable ? "available" : "unavailable", privacy: .public): \(self.unavailableReason ?? "-", privacy: .public)")
            }
        }

        let availability = SystemLanguageModel.default.availability
        let systemReason = Self.reason(for: availability)
        systemModelIsAvailable = systemReason == nil

        if let forced = Self.overrideForTesting {
            isAvailable = forced
            unavailableReason = forced ? nil : Self.settingOffReason
            return
        }

        // The system's own answer comes first. When the Mac cannot run the
        // model at all, saying "turned off in Pharos settings" would send the
        // user to a checkbox that changes nothing.
        if let systemReason {
            isAvailable = false
            unavailableReason = systemReason
            return
        }

        if !enabledInSettings {
            isAvailable = false
            unavailableReason = Self.settingOffReason
            return
        }

        isAvailable = true
        unavailableReason = nil
    }

    // MARK: - Reasons

    static let settingOffReason = String(localized: "Turned off in Pharos settings.")

    /// The user-readable reason, or nil when the model is available.
    ///
    /// `UnavailableReason` is not frozen, so a case added by a later macOS
    /// lands in the `@unknown default` arm rather than breaking the build —
    /// and the sentence there still tells the user what to do.
    private static func reason(for availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return String(localized: "This Mac does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return String(localized: "Apple Intelligence is turned off in System Settings.")
            case .modelNotReady:
                return String(localized: "The on-device model is still downloading. Try again shortly.")
            @unknown default:
                return String(localized: "Apple Intelligence is not available on this Mac right now.")
            }
        }
    }
}
