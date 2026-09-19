// `ModelAvailability`'s per-feature rule: the one place the three answers
// behind an Apple Intelligence feature are put together.
//
// The REAL `AppSettings` is compiled here — `Pharos/Models/Settings.swift` is
// Foundation-only — so the defaults asserted below are the shipped defaults
// and cannot drift from them. Only `AppStateManager` is stood in for: the real
// one reaches the core on `init`, and there is no initialised core behind a
// `swiftc` binary. The stub publishes the two fields this object reads and
// nothing else, and no test asserts anything about the stub itself.
//
// The system's own answer is forced through `systemOverrideForTesting`, so
// "this Mac cannot run the model" is exercised on a Mac that can.
import AppKit
import Combine

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected \(expected), got \(actual)")
    }
}

// MARK: - Stand-in for the one production dependency

@MainActor
final class AppStateManager: ObservableObject {
    static let shared = AppStateManager()
    @Published private(set) var settings = AppSettings()

    func replaceSettings(_ new: AppSettings) { settings = new }
}

// MARK: - Entry point

func runTests() {
    MainActor.assumeIsolated { runTestsOnMain() }
}

@MainActor
private func runTestsOnMain() {
    testEveryFeatureDefaultsToTodaysBehaviour()
    testEveryFeatureIsOffWhenTheMasterIsOff()
    testEveryFeatureIsOffWhenTheSystemModelIsUnavailable()
    testOneFeatureOffLeavesTheOthersOn()
    testEveryFeatureHasItsOwnFlag()
    testTheLiveObjectFollowsTheStoredFlags()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Defaults

/// Every feature ran whenever `useAppleIntelligence` allowed it before these
/// switches existed, so every default has to be ON — including the two the
/// plan first wrote down as OFF. Naming them here is what keeps a shipped
/// default from quietly becoming a behaviour change for an existing user.
@MainActor
private func testEveryFeatureDefaultsToTodaysBehaviour() {
    let defaults = IntelligenceSettings()
    for feature in ModelAvailability.Feature.allCases {
        expect(ModelAvailability.flag(feature, in: defaults),
               "\(feature.rawValue) defaults on, as it behaved before the switch existed")
    }

    // Spelled out as well as looped, so a renamed field cannot pass by
    // dropping out of the loop.
    expect(defaults.describeQuery, "describeQuery default")
    expect(defaults.explainErrors, "explainErrors default")
    expect(defaults.suggestSavedQueryNames, "suggestSavedQueryNames default")
    expect(defaults.nameTabsAutomatically,
           "nameTabsAutomatically default — a tab IS renamed on its first run today")
    expect(defaults.summarisePlans, "summarisePlans default")
    expect(defaults.suggestCharts, "suggestCharts default")
    expect(defaults.allowDraftingWriteStatements,
           "allowDraftingWriteStatements default — a write draft IS offered today, behind its confirmation")
}

// MARK: - The master switch

@MainActor
private func testEveryFeatureIsOffWhenTheMasterIsOff() {
    // Every per-feature flag ON, the master OFF. `modelIsOffered` is what
    // `refresh()` leaves in `isAvailable`, which is false with the master off
    // whatever the Mac can do.
    let allOn = IntelligenceSettings()
    for feature in ModelAvailability.Feature.allCases {
        expect(!ModelAvailability.isAvailable(feature, modelIsOffered: false, flags: allOn),
               "\(feature.rawValue) is off when the master is off, although its own flag is on")
    }

    // And through the live object, on the production path: the stored master
    // switch, not the test override.
    ModelAvailability.overrideForTesting = nil
    ModelAvailability.systemOverrideForTesting = true
    defer { ModelAvailability.systemOverrideForTesting = nil }

    var settings = AppSettings()
    settings.useAppleIntelligence = false
    AppStateManager.shared.replaceSettings(settings)

    for feature in ModelAvailability.Feature.allCases {
        expect(!ModelAvailability.shared.isAvailable(for: feature),
               "\(feature.rawValue) is off through the live object when the master is cleared")
    }
}

// MARK: - The system's answer

/// A Mac that cannot run the model refuses every feature, whatever the master
/// switch and the seven flags say. This is the case no assertion could reach
/// on a Mac that CAN run it, which is why `systemOverrideForTesting` exists.
@MainActor
private func testEveryFeatureIsOffWhenTheSystemModelIsUnavailable() {
    ModelAvailability.overrideForTesting = nil
    ModelAvailability.systemOverrideForTesting = false
    defer { ModelAvailability.systemOverrideForTesting = nil }

    // Master on, every flag on: only the system is saying no.
    AppStateManager.shared.replaceSettings(AppSettings())

    expect(!ModelAvailability.shared.systemModelIsAvailable, "the forced system answer is taken")
    expect(!ModelAvailability.shared.isAvailable, "and the composed answer with it")
    for feature in ModelAvailability.Feature.allCases {
        expect(!ModelAvailability.shared.isAvailable(for: feature),
               "\(feature.rawValue) is off when this Mac cannot run the model")
    }
}

// MARK: - Independence

/// The point of seven switches: one cleared switch must take exactly one
/// feature away. A rule that read the struct rather than the field would pass
/// every test above and fail this one.
@MainActor
private func testOneFeatureOffLeavesTheOthersOn() {
    for off in ModelAvailability.Feature.allCases {
        var flags = IntelligenceSettings()
        set(off, to: false, in: &flags)

        expect(!ModelAvailability.isAvailable(off, modelIsOffered: true, flags: flags),
               "\(off.rawValue) is off once its own flag is cleared")
        for other in ModelAvailability.Feature.allCases where other != off {
            expect(ModelAvailability.isAvailable(other, modelIsOffered: true, flags: flags),
                   "\(other.rawValue) survives \(off.rawValue) being cleared")
        }
    }
}

/// No two cases may read the same field. Clearing each flag in turn and
/// counting what went off catches a copy-paste in the `switch`, which the
/// independence test above would report as a plain failure without saying why.
@MainActor
private func testEveryFeatureHasItsOwnFlag() {
    for off in ModelAvailability.Feature.allCases {
        var flags = IntelligenceSettings()
        set(off, to: false, in: &flags)
        let refused = ModelAvailability.Feature.allCases.filter {
            !ModelAvailability.flag($0, in: flags)
        }
        expectEqual(refused, [off], "clearing \(off.rawValue) refuses exactly one feature")
    }
}

/// Write one feature's flag, by the same mapping the production code reads it
/// through — so a field renamed on one side alone fails to compile here.
@MainActor
private func set(_ feature: ModelAvailability.Feature, to value: Bool, in flags: inout IntelligenceSettings) {
    switch feature {
    case .describeQuery: flags.describeQuery = value
    case .explainErrors: flags.explainErrors = value
    case .suggestSavedQueryNames: flags.suggestSavedQueryNames = value
    case .nameTabsAutomatically: flags.nameTabsAutomatically = value
    case .summarisePlans: flags.summarisePlans = value
    case .suggestCharts: flags.suggestCharts = value
    case .draftWriteStatements: flags.allowDraftingWriteStatements = value
    }
}

// MARK: - The live path

/// The production wiring, end to end: a flag saved in the settings reaches
/// `isAvailable(for:)` through the published settings, with nothing else
/// pushing it, and the publisher delivers the new answer.
@MainActor
private func testTheLiveObjectFollowsTheStoredFlags() {
    ModelAvailability.overrideForTesting = nil
    ModelAvailability.systemOverrideForTesting = true
    defer { ModelAvailability.systemOverrideForTesting = nil }

    AppStateManager.shared.replaceSettings(AppSettings())
    expect(ModelAvailability.shared.isAvailable(for: .explainErrors),
           "every switch on, and the model offered: the feature is available")

    var delivered: [Bool] = []
    let cancellable = ModelAvailability.shared.publisher(for: .explainErrors)
        .sink { delivered.append($0) }

    var settings = AppSettings()
    settings.intelligence.explainErrors = false
    AppStateManager.shared.replaceSettings(settings)

    expect(!ModelAvailability.shared.isAvailable(for: .explainErrors),
           "clearing one flag reaches the live answer")
    expect(ModelAvailability.shared.isAvailable(for: .summarisePlans),
           "and leaves its neighbours alone")
    expectEqual(delivered.last, false, "the publisher delivered the new answer")

    cancellable.cancel()
    AppStateManager.shared.replaceSettings(AppSettings())
}
