import Foundation
import FoundationModels

/// A custom AI endpoint that speaks the OpenAI chat completions format:
/// Ollama, LM Studio, llama.cpp, vLLM, OpenRouter, LiteLLM and most hosted
/// providers.
///
/// Unlike the on-device model, this SENDS the instructions and the prompt to
/// the address the user entered. Nothing here decides whether that is
/// allowed; `ModelAvailability` does, before a feature gets this far.
///
/// One request is one conversation: a system message (the instructions), a
/// user message (the prompt), and nothing kept afterwards.
///
/// The answer is asked for as JSON matching the answer type's schema. An
/// endpoint is not bound by the schema the way the on-device model is, so
/// what comes back is parsed strictly and the feature's own validators still
/// run on it.
@MainActor
final class EndpointIntelligenceBackend: IntelligenceBackend {

    /// Sends one request. A seam: the tests answer from memory.
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// How the endpoint is asked for JSON, most exact first.
    enum StructuredMode: Equatable {
        /// `response_format: json_schema`: the endpoint constrains the answer.
        case jsonSchema
        /// `response_format: json_object`, with the schema in the instructions.
        case jsonObject
        /// No `response_format` at all; the schema is in the instructions.
        case promptOnly

        var next: StructuredMode? {
            switch self {
            case .jsonSchema: return .jsonObject
            case .jsonObject: return .promptOnly
            case .promptOnly: return nil
            }
        }
    }

    /// The window the user entered for this model.
    let contextSize: Int

    private let base: URL
    private let model: String
    /// Read for every request and never kept: the user may change the key
    /// while the app runs.
    private let key: () -> String?
    private let transport: Transport
    /// The session behind the default transport, so it ends with this object.
    private let session: URLSession?

    /// The most exact mode this endpoint has accepted. An endpoint that
    /// refused a mode once is not asked that way again.
    private(set) var mode = StructuredMode.jsonSchema

    /// Long enough for a slow local model, short enough to end a hung one.
    static let timeout: TimeInterval = 120

    init(base: URL, model: String, contextSize: Int, key: @escaping () -> String?, transport: Transport? = nil) {
        self.base = base
        self.model = model
        self.contextSize = contextSize
        self.key = key
        if let transport {
            self.transport = transport
            self.session = nil
        } else {
            let session = IntelligenceEndpoint.makeSession()
            self.session = session
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw IntelligenceEndpointError.unexpectedAnswer }
                return (data, http)
            }
        }
    }

    deinit { session?.finishTasksAndInvalidate() }

    // MARK: - IntelligenceBackend

    func respond<Answer: Generable>(
        instructions: String, prompt: String,
        generating type: Answer.Type, sampling: IntelligenceSampling
    ) async throws -> Answer {
        let content = try await respond(
            instructions: instructions, prompt: prompt, schema: type.generationSchema,
            textLimits: (type as? TextLimitedAnswer.Type)?.textLimits ?? [:], sampling: sampling)
        do {
            return try Answer(content)
        } catch {
            throw IntelligenceEndpointError.unexpectedAnswer
        }
    }

    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        try await respond(instructions: instructions, prompt: prompt, schema: schema, textLimits: [:], sampling: sampling)
    }

    func respond(
        instructions: String, prompt: String,
        schema: GenerationSchema, textLimits: [String: Int], sampling: IntelligenceSampling
    ) async throws -> GeneratedContent {
        let schemaJSON = try Self.schemaText(for: schema, textLimits: textLimits)
        var attempt = mode
        while true {
            let request = try Self.request(
                base: base, model: model, key: key(), instructions: instructions, prompt: prompt,
                schema: schemaJSON, sampling: sampling, mode: attempt)
            let (data, response) = try await send(request)
            // 400 and 422 are how an endpoint says it does not take this
            // `response_format`. They are also how it says other things, so
            // a plainer mode is kept only once it has worked.
            if response.statusCode == 400 || response.statusCode == 422, let plainer = attempt.next {
                attempt = plainer
                continue
            }
            if let failure = IntelligenceEndpointError(status: response.statusCode, model: model) { throw failure }
            let content = try Self.content(from: data)
            mode = attempt
            return content
        }
    }

    /// The whole answer, delivered once. The endpoint is not asked to stream:
    /// a half-written JSON object is not an answer a feature can show.
    func streamResponse<Answer: Generable>(
        instructions: String, prompt: String, generating type: Answer.Type
    ) -> AsyncThrowingStream<Answer.PartiallyGenerated, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let content = try await self.respond(
                        instructions: instructions, prompt: prompt, schema: type.generationSchema,
                        textLimits: (type as? TextLimitedAnswer.Type)?.textLimits ?? [:], sampling: .standard)
                    do {
                        continuation.yield(try Answer.PartiallyGenerated(content))
                    } catch {
                        throw IntelligenceEndpointError.unexpectedAnswer
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An endpoint has no call that counts tokens; the caller keeps its own
    /// estimate against `contextSize`.
    func tokenCount(instructions: String, prompt: String, schema: GenerationSchema) async throws -> Int {
        throw IntelligenceBackendError.tokenCountUnavailable
    }

    // MARK: - Sending

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw IntelligenceEndpointError.timedOut
            default: throw IntelligenceEndpointError.unreachable(error.localizedDescription)
            }
        }
    }

    // MARK: - The request

    /// The answer type's schema as JSON Schema text.
    ///
    /// Two things are done to what FoundationModels encodes.
    ///
    /// `x-order` and `title` mean nothing to an endpoint, and a strict one
    /// refuses them. They are removed at every depth.
    ///
    /// Each object's `properties` are written in the order its `x-order`
    /// gives, which is the order the answer type declares them in. An
    /// endpoint that holds its answer to the schema writes the fields in the
    /// order the schema lists them, as the on-device model does, and the
    /// features rely on that order: a draft's `plan` comes before its `sql`
    /// so that the model decides before it writes, and a reading step names
    /// a table before it lists that table's columns. Every other key is
    /// sorted, so the same schema is always the same text.
    ///
    /// A third thing is added: every free-text string is given a
    /// `maxLength`: the limit `textLimits` names for its field, else
    /// `textLimit`. A local model sampled greedily can fall into repeating
    /// itself inside a string — measured with LM Studio, 2026-11-13: a table
    /// choice whose `reason` ran on until the window was full, about a
    /// minute and a half later. An endpoint that holds its answer to the
    /// schema closes the string at the limit and goes on to the rest of the
    /// answer, so the step still answers, a few seconds late.
    static func schemaText(for schema: GenerationSchema, textLimits: [String: Int] = [:]) throws -> String {
        let data = try JSONEncoder().encode(schema)
        var text = ""
        try write(schema: JSONSerialization.jsonObject(with: data), into: &text, limits: textLimits, limit: textLimit)
        return text
    }

    /// The most characters a free-text field of an answer may hold. Longer
    /// than anything a feature shows — a drafted statement is a few hundred
    /// characters, an explanation a paragraph — and far shorter than a
    /// model's window.
    static let textLimit = 4_000

    /// The keys whose value maps the answer's own names to schemas. Those
    /// names are not schema keywords: a field called "title" stays.
    private static let nameMaps: Set<String> = ["properties", "$defs", "definitions"]

    /// `limit` is what a free-text string written here is held to: its
    /// field's own limit, which a list's strings inherit, else `textLimit`.
    private static func write(
        schema value: Any, into text: inout String, limits: [String: Int], limit: Int
    ) throws {
        if var object = value as? [String: Any] {
            let order = object["x-order"] as? [String] ?? []
            // Free text: a string that is not held to a list, a constant or
            // a pattern, and has no limit of its own.
            if object["type"] as? String == "string",
               object["enum"] == nil, object["const"] == nil, object["pattern"] == nil, object["maxLength"] == nil {
                object["maxLength"] = limit
            }
            text += "{"
            var first = true
            for key in object.keys.sorted() where key != "x-order" && key != "title" {
                if !first { text += "," }
                first = false
                text += try scalar(key) + ":"
                if nameMaps.contains(key), let named = object[key] as? [String: Any] {
                    // Declared order first; a name `x-order` does not list
                    // (a definition, say) follows in sorted order.
                    let listed = key == "properties" ? order.filter { named[$0] != nil } : []
                    let names = listed + named.keys.sorted().filter { !listed.contains($0) }
                    text += "{"
                    for (index, name) in names.enumerated() {
                        if index > 0 { text += "," }
                        text += try scalar(name) + ":"
                        // A field starts again from its own limit; a
                        // definition is not a field and has none.
                        let own = key == "properties" ? (limits[name] ?? textLimit) : textLimit
                        try write(schema: named[name] as Any, into: &text, limits: limits, limit: own)
                    }
                    text += "}"
                } else {
                    try write(schema: object[key] as Any, into: &text, limits: limits, limit: limit)
                }
            }
            text += "}"
        } else if let array = value as? [Any] {
            text += "["
            for (index, element) in array.enumerated() {
                if index > 0 { text += "," }
                try write(schema: element, into: &text, limits: limits, limit: limit)
            }
            text += "]"
        } else {
            text += try scalar(value)
        }
    }

    /// A string, number, boolean or null as JSON.
    private static func scalar(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    /// Stands where the schema goes while the rest of the body is
    /// serialized. `JSONSerialization` writes a dictionary's keys in an
    /// order of its own, so the schema, whose order matters, is written by
    /// hand and put in afterwards.
    private static let schemaPlaceholder = "@@PHAROS-ANSWER-SCHEMA@@"

    /// `POST <base>/chat/completions`.
    static func request(
        base: URL, model: String, key: String?, instructions: String, prompt: String,
        schema: String, sampling: IntelligenceSampling, mode: StructuredMode
    ) throws -> URLRequest {
        var system = instructions
        if mode != .jsonSchema {
            system += "\n\nAnswer with one JSON object and nothing else. It must match this JSON Schema:\n" + schema
        }
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]
        switch mode {
        case .jsonSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "answer", "schema": schemaPlaceholder],
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptOnly:
            break
        }
        if sampling == .greedy { body["temperature"] = 0 }

        var request = URLRequest(url: base.appendingPathComponent("chat").appendingPathComponent("completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        var json = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        // Only the placeholder written above can match: a quote inside the
        // instructions or the prompt is escaped by the serializer, so no
        // text of theirs can spell `"schema":"…"`.
        if mode == .jsonSchema,
           let range = json.range(of: "\"schema\":" + (try scalar(schemaPlaceholder))) {
            json.replaceSubrange(range, with: "\"schema\":" + schema)
        }
        request.httpBody = Data(json.utf8)
        return request
    }

    // MARK: - The answer

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    /// The JSON object in a chat completion, as generated content.
    static func content(from data: Data) throws -> GeneratedContent {
        guard let choice = (try? JSONDecoder().decode(Completion.self, from: data))?.choices.first else {
            throw IntelligenceEndpointError.unexpectedAnswer
        }
        if let refusal = choice.message.refusal, !refusal.isEmpty { throw IntelligenceEndpointError.refused }
        if choice.finish_reason == "content_filter" { throw IntelligenceEndpointError.refused }
        // Cut off by the window or the answer limit: what is there is half
        // an object.
        if choice.finish_reason == "length" { throw IntelligenceEndpointError.tooLong }
        guard let text = choice.message.content, let json = jsonObject(in: text) else {
            throw IntelligenceEndpointError.unexpectedAnswer
        }
        do {
            return try GeneratedContent(json: json)
        } catch {
            throw IntelligenceEndpointError.unexpectedAnswer
        }
    }

    /// The JSON object inside a model's message, or nil when there is none.
    ///
    /// A model asked for JSON alone still sometimes shows its reasoning in a
    /// `<think>` block first, wraps the object in a code fence, or adds a
    /// sentence round it. The object is what lies between the first `{` and
    /// the last `}` once the reasoning is gone; whether it is VALID is for
    /// the parser that reads it next.
    static func jsonObject(in message: String) -> String? {
        var text = message
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return nil }
        return String(text[first...last])
    }
}

// MARK: - Errors

/// What went wrong asking a custom endpoint. Each has a sentence for the
/// user and a `ModelErrorKind` for the log; neither carries the prompt, the
/// answer or the key.
enum IntelligenceEndpointError: LocalizedError, Equatable, ModelErrorKindProviding {
    /// 401 or 403.
    case keyRefused
    /// 404: no such model, or no API at the address.
    case modelNotFound(String)
    /// 429.
    case rateLimited
    /// The request or the answer did not fit the model's window.
    case tooLong
    case refused
    /// The answer was not the JSON that was asked for.
    case unexpectedAnswer
    case timedOut
    /// No answer at all. The string is the system's own sentence.
    case unreachable(String)
    case httpStatus(Int)
    /// The endpoint's settings are incomplete. The string says what is missing.
    case notSetUp(String)

    /// The error for an HTTP status, or nil for a success.
    init?(status: Int, model: String) {
        switch status {
        case 200..<300: return nil
        case 401, 403: self = .keyRefused
        case 404: self = .modelNotFound(model)
        case 408, 504: self = .timedOut
        case 413: self = .tooLong
        case 429: self = .rateLimited
        default: self = .httpStatus(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .keyRefused:
            return String(localized: "The endpoint refused the API key. Check it in Settings ▸ Intelligence.")
        case .modelNotFound(let model):
            return String(localized: "The endpoint has no model named \u{201C}\(model)\u{201D}. Check the address and the model name in Settings ▸ Intelligence.")
        case .rateLimited:
            return String(localized: "The endpoint is busy or over its limit. Try again shortly.")
        case .tooLong:
            return String(localized: "That was too much for this model in one request.")
        case .refused:
            return String(localized: "The model declined to answer.")
        case .unexpectedAnswer:
            return String(localized: "The model's answer was not in the form Pharos asked for. Try again, or use another model.")
        case .timedOut:
            return String(localized: "The endpoint did not answer in time.")
        case .unreachable(let reason):
            return String(localized: "The endpoint could not be reached. \(reason)")
        case .httpStatus(let status):
            return String(localized: "The endpoint answered with an error (HTTP \(status)).")
        case .notSetUp(let what):
            return what
        }
    }

    var modelErrorKind: ModelErrorKind {
        switch self {
        case .keyRefused: return .other("endpoint.keyRefused")
        case .modelNotFound: return .other("endpoint.modelNotFound")
        case .rateLimited: return .rateLimited
        case .tooLong: return .contextSizeExceeded
        case .refused: return .refusal
        case .unexpectedAnswer: return .decodingFailure
        case .timedOut: return .timeout
        case .unreachable: return .other("endpoint.unreachable")
        case .httpStatus(let status): return .other("endpoint.http\(status)")
        case .notSetUp: return .other("endpoint.notSetUp")
        }
    }
}
