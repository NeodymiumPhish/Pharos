import Foundation
import FoundationModels

/// What went wrong in a model request, whichever error type reported it.
///
/// macOS 26 throws `LanguageModelSession.GenerationError`. macOS 27 throws
/// `LanguageModelError` (and `SystemLanguageModel.Error`,
/// `LanguageModelSession.Error`) instead — measured on macOS 27.0: a context
/// overflow arrives as `FoundationModels.LanguageModelError`, and
/// `error is GenerationError` is false. A handler that switches on
/// `GenerationError` alone therefore shows its generic message for every
/// failure on macOS 27.
///
/// The macOS 27 types cannot be named here: release CI builds with the
/// macOS 26.6 SDK, where they do not exist (see the release SDK ceiling
/// note). Their case names are read through `Mirror` instead, which works
/// with either SDK. Only the case name is read, never a payload: a
/// payload's context can describe the prompt.
enum ModelErrorKind: Equatable {
    case contextSizeExceeded
    case guardrailViolation
    case unsupportedLanguageOrLocale
    case refusal
    case rateLimited
    case timeout
    case assetsUnavailable
    case decodingFailure
    case concurrentRequests
    /// Anything else: the type name, or `Type.case` for a FoundationModels
    /// enum this list does not know.
    case other(String)

    static func of(_ error: Error) -> ModelErrorKind {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return .contextSizeExceeded
            case .guardrailViolation: return .guardrailViolation
            case .unsupportedLanguageOrLocale: return .unsupportedLanguageOrLocale
            case .refusal: return .refusal
            case .rateLimited: return .rateLimited
            case .assetsUnavailable: return .assetsUnavailable
            case .decodingFailure: return .decodingFailure
            case .concurrentRequests: return .concurrentRequests
            default: return .other("GenerationError")
            }
        }
        let typeName = String(reflecting: type(of: error))
        guard typeName.hasPrefix("FoundationModels.") else {
            return .other(String(describing: type(of: error)))
        }
        // A case with a payload is the mirror's one labelled child. A case
        // without one has no child, and its description is the error's
        // message, not its name, so it is not read.
        let mirror = Mirror(reflecting: error)
        let caseName = mirror.displayStyle == .enum ? mirror.children.first?.label ?? "" : ""
        return ModelErrorKind(caseName: caseName, typeName: String(describing: type(of: error)))
    }

    /// The macOS 27 case names (`LanguageModelError`,
    /// `SystemLanguageModel.Error`, `LanguageModelSession.Error`).
    init(caseName: String, typeName: String) {
        switch caseName {
        case "contextSizeExceeded", "exceededContextWindowSize": self = .contextSizeExceeded
        case "guardrailViolation": self = .guardrailViolation
        case "unsupportedLanguageOrLocale": self = .unsupportedLanguageOrLocale
        case "refusal": self = .refusal
        case "rateLimited": self = .rateLimited
        case "timeout": self = .timeout
        case "assetsUnavailable": self = .assetsUnavailable
        case "decodingFailure": self = .decodingFailure
        case "concurrentRequests": self = .concurrentRequests
        default: self = .other(caseName.isEmpty ? typeName : "\(typeName).\(caseName)")
        }
    }

    /// For the log: a fixed word, safe as public data.
    var name: String {
        switch self {
        case .contextSizeExceeded: return "contextSizeExceeded"
        case .guardrailViolation: return "guardrailViolation"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .refusal: return "refusal"
        case .rateLimited: return "rateLimited"
        case .timeout: return "timeout"
        case .assetsUnavailable: return "assetsUnavailable"
        case .decodingFailure: return "decodingFailure"
        case .concurrentRequests: return "concurrentRequests"
        case .other(let name): return name
        }
    }
}
