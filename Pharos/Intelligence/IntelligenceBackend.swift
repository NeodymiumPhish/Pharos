import Foundation
import FoundationModels

/// The model behind every intelligence feature, as the features see it.
///
/// A feature builds its instructions and its prompt, asks a backend for an
/// answer of a `Generable` type, and validates what comes back. It never
/// opens a session itself, so which model answered is decided in one place:
/// `IntelligenceBackends.current`.
///
/// One request is one conversation. Every method starts from the
/// instructions and the prompt alone and keeps nothing afterwards, which is
/// what each feature already did with a new `LanguageModelSession` per call.
///
/// The answer types stay FoundationModels' own. A `GenerationSchema` encodes
/// as JSON Schema and a `GeneratedContent` is built from JSON, so a backend
/// that is not the on-device model can carry the same types over a wire.
@MainActor
protocol IntelligenceBackend {

    /// The size of the model's window, in tokens. A prompt is budgeted
    /// against it.
    var contextSize: Int { get }

    /// One answer of a type known at compile time.
    func respond<Answer: Generable>(
        instructions: String, prompt: String,
        generating type: Answer.Type, sampling: IntelligenceSampling
    ) async throws -> Answer

    /// One answer to a schema built at run time, such as a choice held to a
    /// list of names.
    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, sampling: IntelligenceSampling
    ) async throws -> GeneratedContent

    /// One answer to a schema built at run time, with the most characters
    /// each named free-text field of the answer may hold (`textLimits`: a
    /// field's name to its limit, at any depth; a list of strings takes its
    /// own name's limit for each string).
    ///
    /// The limit is for a backend that can be held to one and needs it: an
    /// endpoint's model can run on inside a field until its window is full.
    /// The on-device model is not asked to keep to it and does not need to
    /// be; the default below ignores the limits.
    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, textLimits: [String: Int], sampling: IntelligenceSampling
    ) async throws -> GeneratedContent

    /// One answer as it fills in. Each element is the whole answer so far.
    /// Dropping the stream cancels the generation.
    func streamResponse<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type
    ) -> AsyncThrowingStream<Answer.PartiallyGenerated, Error>

    /// What the instructions, the prompt and the answer's schema cost
    /// together. Throws `IntelligenceBackendError.tokenCountUnavailable`
    /// where the model cannot say; the caller then keeps its own estimate.
    func tokenCount(instructions: String, prompt: String, schema: GenerationSchema) async throws -> Int
}

extension IntelligenceBackend {
    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, textLimits: [String: Int], sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        try await respond(instructions: instructions, prompt: prompt, schema: schema, sampling: sampling)
    }
}

/// An answer type that says how long its free-text fields may be, for a
/// backend that can hold an answer to that (see
/// `IntelligenceBackend.respond(instructions:prompt:schema:textLimits:sampling:)`).
/// A field it does not name gets the backend's own limit.
protocol TextLimitedAnswer {
    /// A field's name to the most characters it may hold.
    static var textLimits: [String: Int] { get }
}

/// How the model chooses each token.
enum IntelligenceSampling {
    /// The model's own default.
    case standard
    /// Always the likeliest token: the same request gives the same answer,
    /// so a bad one can be reproduced.
    case greedy
}

enum IntelligenceBackendError: Error {
    case tokenCountUnavailable
}

// MARK: - Which backend

/// The backend the features use.
@MainActor
enum IntelligenceBackends {

    /// Test seam, the same idea as `ModelAvailability.overrideForTesting`:
    /// answer from a stand-in without a real model. Production code never
    /// sets it.
    static var overrideForTesting: IntelligenceBackend?

    /// The custom endpoint, when the user has chosen one; nil while Apple's
    /// model is chosen. Installed at launch
    /// (`IntelligenceBackends.followSettings()`), because the settings live
    /// in the app and this file is also compiled without it. Nil here means
    /// the on-device model, so it must never answer nil for a chosen
    /// endpoint that is merely unusable.
    static var endpoint: (() -> IntelligenceBackend?)?

    /// Read at the start of each request, never kept across requests.
    static var current: IntelligenceBackend { overrideForTesting ?? endpoint?() ?? apple }

    private static let apple = AppleIntelligenceBackend()
}

// MARK: - The on-device model

/// Apple's on-device `SystemLanguageModel`. Nothing here sends anything
/// anywhere.
///
/// Each call is exactly the FoundationModels call the feature made before
/// this type existed: a new session from the instructions, then one request
/// with the same arguments. `.standard` passes no options at all, not a
/// default-valued `GenerationOptions`, so the request is the one the
/// evaluations measured.
@MainActor
final class AppleIntelligenceBackend: IntelligenceBackend {

    private let model = SystemLanguageModel.default

    var contextSize: Int { model.contextSize }

    /// The macOS 27 SDK renames `sampling:` to `samplingMode:` (back-deployed,
    /// so it runs on macOS 26 too) and deprecates the old name; the macOS 26
    /// SDK of release CI (Xcode 26.6, Swift 6.3) has only the old name.
    /// Swift 6.4 comes with the macOS 27 SDK, so the compiler version picks
    /// the spelling. Drop the `#else` once release CI builds with Xcode 27.
    #if compiler(>=6.4)
    private let greedy = GenerationOptions(samplingMode: .greedy)
    #else
    private let greedy = GenerationOptions(sampling: .greedy)
    #endif

    func respond<Answer: Generable>(
        instructions: String, prompt: String,
        generating type: Answer.Type, sampling: IntelligenceSampling
    ) async throws -> Answer {
        let session = LanguageModelSession(instructions: instructions)
        switch sampling {
        case .standard:
            return try await session.respond(to: prompt, generating: type).content
        case .greedy:
            return try await session.respond(to: prompt, generating: type, options: greedy).content
        }
    }

    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        let session = LanguageModelSession(instructions: instructions)
        switch sampling {
        case .standard:
            return try await session.respond(to: prompt, schema: schema).content
        case .greedy:
            return try await session.respond(to: prompt, schema: schema, options: greedy).content
        }
    }

    func streamResponse<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type
    ) -> AsyncThrowingStream<Answer.PartiallyGenerated, Error> {
        let session = LanguageModelSession(instructions: instructions)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await snapshot in session.streamResponse(to: prompt, generating: type) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func tokenCount(instructions: String, prompt: String, schema: GenerationSchema) async throws -> Int {
        guard #available(macOS 26.4, *) else { throw IntelligenceBackendError.tokenCountUnavailable }
        let a = try await model.tokenCount(for: Instructions(instructions))
        let b = try await model.tokenCount(for: prompt)
        let c = try await model.tokenCount(for: schema)
        return a + b + c
    }
}
