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

    /// The same seam one level lower: force what the SYSTEM says, and leave
    /// the Pharos settings to answer for themselves.
    ///
    /// `overrideForTesting` cannot stand in for this. It replaces the composed
    /// answer, so a test written with it cannot tell "this Mac cannot run the
    /// model" apart from "the user cleared the switch" — and the per-feature
    /// rule has to refuse in the first case whatever the flags say. Production
    /// code never sets it.
    static var systemOverrideForTesting: Bool? {
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

    /// Whether the model the user CHOSE can be asked, ignoring the master
    /// switch: the on-device model on a Mac that runs it, or a custom
    /// endpoint with an address and a model name. The master switch in
    /// Settings follows this one.
    @Published private(set) var providerIsUsable: Bool = false

    /// "Use Apple Intelligence features", as last PUBLISHED.
    ///
    /// Cached, not re-read. `@Published` notifies its subscribers on `willSet`,
    /// so a sink that reaches back for `AppStateManager.shared.settings` reads
    /// the value the user has just replaced — the switch would appear to take
    /// one change to take effect. The delivered value is the only correct one
    /// at that moment, and every later reader wants the same value.
    private var enabledInSettings = true

    /// The seven per-feature switches, as last PUBLISHED.
    ///
    /// Published in its own right so a view can follow one feature without
    /// polling, and cached for the same `willSet` reason as
    /// `enabledInSettings` above. Read through `isAvailable(for:)`, never on
    /// its own: a flag that is on still means nothing on a Mac that cannot run
    /// the model.
    @Published private(set) var features = IntelligenceSettings()

    /// The two stored fields this object follows, as one value.
    ///
    /// A named struct rather than a tuple: `removeDuplicates` over a tuple
    /// needs a hand-written comparator, and that expression defeated the
    /// type-checker outright ("unable to type-check in reasonable time").
    private struct StoredInputs: Equatable {
        let master: Bool
        let features: IntelligenceSettings

        init(_ settings: AppSettings) {
            master = settings.useAppleIntelligence
            features = settings.intelligence
        }
    }

    private var settingsCancellable: AnyCancellable?
    private var activeObserver: NSObjectProtocol?

    private init() {
        // The publisher delivers the current value on subscribe, so this also
        // seeds `enabledInSettings` — one code path for launch and change, as
        // `ThemeApplier` does it.
        settingsCancellable = AppStateManager.shared.$settings
            .map(StoredInputs.init)
            .removeDuplicates()
            .sink { [weak self] inputs in
                self?.enabledInSettings = inputs.master
                self?.features = inputs.features
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

        let systemReason: String?
        if let forcedSystem = Self.systemOverrideForTesting {
            systemReason = forcedSystem ? nil : Self.genericUnavailableReason
        } else {
            systemReason = Self.reason(for: SystemLanguageModel.default.availability)
        }
        systemModelIsAvailable = systemReason == nil

        if let forced = Self.overrideForTesting {
            isAvailable = forced
            unavailableReason = forced ? nil : Self.settingOffReason
            return
        }

        // Whether the CHOSEN model can answer. With the custom endpoint
        // chosen, what this Mac can run is beside the point: the endpoint
        // answers or nothing does, and the on-device model never stands in
        // for it.
        let providerReason = features.provider == .endpoint ? Self.endpointProblem(features.endpoint) : systemReason
        providerIsUsable = providerReason == nil

        // The provider's own answer comes first. When the model cannot be
        // asked at all, saying "turned off in Pharos settings" would send
        // the user to a checkbox that changes nothing.
        if let providerReason {
            isAvailable = false
            unavailableReason = providerReason
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

    static let endpointNotSetUpReason = String(
        localized: "The custom endpoint is not set up. Enter its address and model name in Settings ▸ Intelligence.")

    /// The endpoint is on another machine and the user has not agreed to
    /// send to it.
    static func endpointNotAllowedReason(host: String) -> String {
        String(localized: "You have not allowed Pharos to send to \(host). Allow it in Settings ▸ Intelligence.")
    }

    /// Why the custom endpoint cannot be asked, or nil when it can.
    ///
    /// "Can be asked" means it has a usable address and a model name, and,
    /// when it is on another machine, the user's agreement to that host. It
    /// does not mean anything answers there: that is found out by asking,
    /// and the failure then names itself.
    static func endpointProblem(_ endpoint: IntelligenceEndpointSettings) -> String? {
        switch IntelligenceEndpoint.baseURL(from: endpoint.baseUrl) {
        case .failure(.empty):
            return endpointNotSetUpReason
        case .failure(let problem):
            return problem.message
        case .success(let base):
            let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return endpointNotSetUpReason }
            if let host = IntelligenceEndpoint.hostNeedingPermission(base: base, allowedHost: endpoint.allowedHost) {
                return endpointNotAllowedReason(host: host)
            }
            return nil
        }
    }

    /// The sentence for a Mac that cannot run the model and will not say why.
    static let genericUnavailableReason = String(
        localized: "Apple Intelligence is not available on this Mac right now.")

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
                return genericUnavailableReason
            }
        }
    }
}

// MARK: - The per-feature switches

extension ModelAvailability {

    /// One Apple Intelligence feature, as Settings ▸ Intelligence lists them.
    ///
    /// Every feature site asks `isAvailable(for:)` rather than `isAvailable`,
    /// so turning one feature off cannot be mistaken for turning the model off.
    enum Feature: String, CaseIterable {
        /// The Describe button in each query card's name row.
        case describeQuery
        /// The explanation block on the query-error sheet.
        case explainErrors
        /// A suggested name in the Save Query sheet and the card rename dialog.
        case suggestSavedQueryNames
        /// Naming an unnamed query card from its SQL on its first run. The
        /// stored key keeps its old name: it once named editor tabs too.
        case nameTabsAutomatically
        /// The plan summary above an EXPLAIN result.
        case summarisePlans
        /// "Suggest chart" asking the model instead of the recommender.
        case suggestCharts
        /// Whether a draft that is not a plain read may be offered at all.
        case draftWriteStatements
    }

    /// Whether `feature` may run right now.
    ///
    /// Three things have to hold, and this is the only place they are put
    /// together: the Mac can run the model, the master switch is on (those two
    /// are `isAvailable`), and the feature's own switch is on.
    func isAvailable(for feature: Feature) -> Bool {
        Self.isAvailable(feature, modelIsOffered: isAvailable, flags: features)
    }

    /// The composition rule on its own.
    ///
    /// Pure, so every combination — including "this Mac cannot run the model",
    /// which no assertion could otherwise reach on a Mac that can — is
    /// testable. `modelIsOffered` is `systemModelIsAvailable && the master
    /// switch`, which is exactly what `refresh()` leaves in `isAvailable`.
    static func isAvailable(_ feature: Feature, modelIsOffered: Bool, flags: IntelligenceSettings) -> Bool {
        modelIsOffered && flag(feature, in: flags)
    }

    /// One feature's own switch, ignoring everything else.
    static func flag(_ feature: Feature, in flags: IntelligenceSettings) -> Bool {
        switch feature {
        case .describeQuery: return flags.describeQuery
        case .explainErrors: return flags.explainErrors
        case .suggestSavedQueryNames: return flags.suggestSavedQueryNames
        case .nameTabsAutomatically: return flags.nameTabsAutomatically
        case .summarisePlans: return flags.summarisePlans
        case .suggestCharts: return flags.suggestCharts
        case .draftWriteStatements: return flags.allowDraftingWriteStatements
        }
    }

    /// One feature's answer, whenever anything that decides it changes.
    ///
    /// The value is DELIVERED rather than left to be read back. `@Published`
    /// notifies on `willSet`, so a sink that reaches for `isAvailable(for:)`
    /// reads the value it is being told is about to be replaced — the bug this
    /// object's own header describes, once per feature site.
    func publisher(for feature: Feature) -> AnyPublisher<Bool, Never> {
        Publishers.CombineLatest($isAvailable, $features)
            .map { Self.isAvailable(feature, modelIsOffered: $0, flags: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
