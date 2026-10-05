import Foundation
import FoundationModels

// ModelErrorKind: one meaning for a model failure on macOS 26 and 27. Run by
// scripts/test-model-error-kind.sh. The macOS 27 type itself was checked
// against the real model on macOS 27.0: a context overflow is
// FoundationModels.LanguageModelError, its Mirror is an enum whose one child
// is labelled "contextSizeExceeded", and `is GenerationError` is false.

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected \(expected), got \(actual)")
    }
}

private struct Unrelated: Error {}

func runTests() {
    let context = LanguageModelSession.GenerationError.Context(debugDescription: "the prompt text")
    expectEqual(ModelErrorKind.of(LanguageModelSession.GenerationError.exceededContextWindowSize(context)),
                .contextSizeExceeded, "macOS 26: a GenerationError overflow")
    expectEqual(ModelErrorKind.of(LanguageModelSession.GenerationError.guardrailViolation(context)),
                .guardrailViolation, "macOS 26: a guardrail")
    expectEqual(ModelErrorKind(caseName: "contextSizeExceeded", typeName: "LanguageModelError"),
                .contextSizeExceeded, "macOS 27: the overflow case name")
    expectEqual(ModelErrorKind(caseName: "assetsUnavailable", typeName: "Error"),
                .assetsUnavailable, "macOS 27: SystemLanguageModel.Error")
    expectEqual(ModelErrorKind(caseName: "somethingNew", typeName: "LanguageModelError"),
                .other("LanguageModelError.somethingNew"), "an unknown case keeps its name")
    expectEqual(ModelErrorKind(caseName: "", typeName: "LanguageModelError"),
                .other("LanguageModelError"), "a case with no payload falls back to the type")
    expectEqual(ModelErrorKind.of(Unrelated()), .other("Unrelated"), "a non-model error is its type name")
    expectEqual(ModelErrorKind.of(CancellationError()).name, "CancellationError", "the log name")
    expectEqual(ModelErrorKind.of(LanguageModelSession.GenerationError.exceededContextWindowSize(context)).name
                    .contains("prompt"), false, "the payload never reaches the name")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    if failures > 0 { exit(1) }
}
