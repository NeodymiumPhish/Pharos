import Foundation
import FoundationModels

// Tests for `EndpointIntelligenceBackend`, run by
// scripts/test-endpoint-backend.sh. The transport is replaced by a queue of
// canned HTTP answers that records each request, so these check the wire
// format and the handling of every kind of answer without a network.

private var failures = 0
private var passes = 0

private func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    expect(a == b, "\(message)\n    got:      \(a)\n    expected: \(b)", line: line)
}

// MARK: - Answer types

@Generable
private struct Explanation {
    @Guide(description: "one sentence naming the cause")
    var cause: String
    var location: String?
    @Guide(description: "fixes", .count(1...3))
    var fixes: [String]
}

/// A field called `title`: the schema keyword of the same name is removed,
/// the field must not be.
@Generable
private struct Titled {
    var title: String
}

// MARK: - The stand-in transport

@MainActor
private final class Wire {
    enum Reply {
        case http(Int, String)
        case fails(Error)
    }

    var replies: [Reply] = []
    private(set) var requests: [URLRequest] = []

    func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        case .fails(let error):
            throw error
        }
    }

    func body(_ index: Int) -> [String: Any] {
        guard index < requests.count, let data = requests[index].httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func systemMessage(_ index: Int) -> String {
        let messages = body(index)["messages"] as? [[String: String]] ?? []
        return messages.first { $0["role"] == "system" }?["content"] ?? ""
    }
}

/// A chat completion whose message is `content`.
private func completion(_ content: String, finish: String = "stop", refusal: String? = nil) -> String {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if let refusal { message["refusal"] = refusal }
    let object: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finish]]]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private let goodAnswer = #"{"cause":"no such column","location":null,"fixes":["check the name"]}"#

@MainActor
private func backend(_ wire: Wire, key: String? = "sk-test") -> EndpointIntelligenceBackend {
    EndpointIntelligenceBackend(
        base: URL(string: "https://api.example.com/v1")!, model: "test-model", contextSize: 32768,
        key: { key }, transport: wire.transport)
}

@MainActor
private func ask(_ backend: EndpointIntelligenceBackend, sampling: IntelligenceSampling = .standard) async throws -> Explanation {
    try await backend.respond(instructions: "INSTRUCTIONS", prompt: "PROMPT", generating: Explanation.self, sampling: sampling)
}

@MainActor
private func failure(_ replies: [Wire.Reply]) async -> Error? {
    let wire = Wire()
    wire.replies = replies
    do {
        _ = try await ask(backend(wire))
        return nil
    } catch {
        return error
    }
}

// MARK: - Tests

@MainActor
private func testRequestShape() async {
    let wire = Wire()
    wire.replies = [.http(200, completion(goodAnswer))]
    let answer = try? await ask(backend(wire))
    expectEqual(answer?.cause, "no such column", "the answer is decoded")
    expect(answer?.location == nil, "a null optional is nil")
    expectEqual(answer?.fixes ?? [], ["check the name"], "the list is decoded")

    expectEqual(wire.requests.count, 1, "one request")
    guard let request = wire.requests.first else { return }
    expectEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions", "chat completions under the root")
    expectEqual(request.httpMethod, "POST", "a POST")
    expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test", "the key is a bearer token")
    expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "JSON goes out")
    expect(request.url?.query == nil, "nothing rides in the address")

    let body = wire.body(0)
    expectEqual(body["model"] as? String, "test-model", "the configured model")
    expectEqual(body["stream"] as? Bool, false, "not streamed")
    expect(body["temperature"] == nil, "standard sampling sends no temperature")
    let messages = body["messages"] as? [[String: String]] ?? []
    expectEqual(messages.map { $0["role"] ?? "" }, ["system", "user"], "instructions, then the prompt")
    expectEqual(messages.first?["content"], "INSTRUCTIONS", "the instructions are sent as written")
    expectEqual(messages.last?["content"], "PROMPT", "the prompt is sent as written")

    let format = body["response_format"] as? [String: Any]
    expectEqual(format?["type"] as? String, "json_schema", "the schema is asked for first")
    let schema = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    expectEqual(schema?["type"] as? String, "object", "the answer type's schema")
    expect(schema?["x-order"] == nil && schema?["title"] == nil, "FoundationModels' own keywords are removed")
    let properties = schema?["properties"] as? [String: Any]
    expectEqual(Set(properties?.keys.map { $0 } ?? []), ["cause", "location", "fixes"], "every field is described")
    expectEqual(Set(schema?["required"] as? [String] ?? []), ["cause", "fixes"], "the optional field is not required")
    let fixes = properties?["fixes"] as? [String: Any]
    expectEqual(fixes?["maxItems"] as? Int, 3, "the count guide survives")
}

@MainActor
private func testGreedyAndKeyless() async {
    let wire = Wire()
    wire.replies = [.http(200, completion(goodAnswer))]
    _ = try? await ask(backend(wire, key: nil), sampling: .greedy)
    expectEqual(wire.body(0)["temperature"] as? Int, 0, "greedy is temperature 0")
    expect(wire.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "no key, no header")

    let empty = Wire()
    empty.replies = [.http(200, completion(goodAnswer))]
    _ = try? await ask(backend(empty, key: ""))
    expect(empty.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "an empty key sends no header")
}

@MainActor
private func testFieldNamedTitleIsKept() async {
    let wire = Wire()
    wire.replies = [.http(200, completion(#"{"title":"Recent Orders"}"#))]
    let answer = try? await backend(wire).respond(
        instructions: "I", prompt: "P", generating: Titled.self, sampling: .standard)
    expectEqual(answer?.title, "Recent Orders", "a field called title is decoded")
    let format = wire.body(0)["response_format"] as? [String: Any]
    let schema = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    expect((schema?["properties"] as? [String: Any])?["title"] != nil, "and stays in the schema's properties")
    expect(schema?["title"] == nil, "while the schema's own title keyword goes")
}

@MainActor
private func testMessyAnswers() async {
    for (name, content) in [
        ("a code fence", "```json\n\(goodAnswer)\n```"),
        ("a sentence round it", "Here is the answer:\n\(goodAnswer)\nHope that helps."),
        ("a reasoning block", "<think>The user {wants} a cause.</think>\n\(goodAnswer)"),
        ("an extra field", #"{"cause":"no such column","fixes":["check the name"],"confidence":0.9}"#),
    ] {
        let wire = Wire()
        wire.replies = [.http(200, completion(content))]
        let answer = try? await ask(backend(wire))
        expectEqual(answer?.cause, "no such column", "\(name) is read through")
    }
    expectEqual(EndpointIntelligenceBackend.jsonObject(in: "no braces"), nil, "no object, no answer")
    expectEqual(EndpointIntelligenceBackend.jsonObject(in: "} {"), nil, "braces the wrong way round")
    expectEqual(EndpointIntelligenceBackend.jsonObject(in: "<think>{a}</think><think>{b}</think> {\"c\":1} "), "{\"c\":1}", "every reasoning block goes")
}

@MainActor
private func testBadAnswers() async {
    let cases: [(String, [Wire.Reply], IntelligenceEndpointError)] = [
        ("prose", [.http(200, completion("I cannot produce JSON."))], .unexpectedAnswer),
        ("broken JSON", [.http(200, completion(#"{"cause": "x", "fixes": ["#))], .unexpectedAnswer),
        ("a missing required field", [.http(200, completion(#"{"fixes":["a"]}"#))], .unexpectedAnswer),
        ("a wrong type", [.http(200, completion(#"{"cause":"x","fixes":"not a list"}"#))], .unexpectedAnswer),
        ("not a completion", [.http(200, #"{"error":"nope"}"#)], .unexpectedAnswer),
        ("no choices", [.http(200, #"{"choices":[]}"#)], .unexpectedAnswer),
        ("a web page", [.http(200, "<html></html>")], .unexpectedAnswer),
        ("a refusal", [.http(200, completion("", refusal: "I can't help with that."))], .refused),
        ("a content filter", [.http(200, completion("", finish: "content_filter"))], .refused),
        ("a cut-off answer", [.http(200, completion(#"{"cause":"x","fix"#, finish: "length"))], .tooLong),
    ]
    for (name, replies, expected) in cases {
        let error = await failure(replies)
        expectEqual(error as? IntelligenceEndpointError, expected, "\(name)")
    }
}

@MainActor
private func testStatuses() async {
    let cases: [(Int, IntelligenceEndpointError)] = [
        (401, .keyRefused), (403, .keyRefused), (404, .modelNotFound("test-model")), (408, .timedOut),
        (413, .tooLong), (429, .rateLimited), (500, .httpStatus(500)), (503, .httpStatus(503)), (504, .timedOut),
    ]
    for (status, expected) in cases {
        let error = await failure([.http(status, #"{"error":{"message":"secret detail"}}"#)])
        expectEqual(error as? IntelligenceEndpointError, expected, "HTTP \(status)")
        expect(error?.localizedDescription.contains("secret detail") == false, "HTTP \(status): the body is not shown")
        expect(error?.localizedDescription.isEmpty == false, "HTTP \(status) has a sentence")
    }
}

@MainActor
private func testTransportFailures() async {
    let timedOut = await failure([.fails(URLError(.timedOut))])
    expectEqual(timedOut as? IntelligenceEndpointError, .timedOut, "a timeout")
    let offline = await failure([.fails(URLError(.cannotConnectToHost))])
    if case .unreachable = offline as? IntelligenceEndpointError {
        expect(true, "no connection is unreachable")
    } else {
        expect(false, "no connection must be unreachable, got \(String(describing: offline))")
    }
    let cancelled = await failure([.fails(URLError(.cancelled))])
    expect(cancelled is CancellationError, "a cancelled request is a cancellation, not a failure to show")
}

@MainActor
private func testStepsDownWhenTheSchemaIsRefused() async {
    let wire = Wire()
    wire.replies = [.http(400, "{}"), .http(200, completion(goodAnswer)), .http(200, completion(goodAnswer))]
    let endpoint = backend(wire)
    expectEqual(endpoint.mode, .jsonSchema, "the exact way is tried first")
    let first = try? await ask(endpoint)
    expectEqual(first?.cause, "no such column", "the second way answers")
    expectEqual(wire.requests.count, 2, "one refusal, one answer")
    expectEqual((wire.body(1)["response_format"] as? [String: Any])?["type"] as? String, "json_object", "the plainer format")
    expect(wire.systemMessage(1).hasPrefix("INSTRUCTIONS"), "the instructions still lead")
    expect(wire.systemMessage(1).contains("JSON Schema") && wire.systemMessage(1).contains("\"cause\""),
           "and the schema is now written out in them")
    expect(!wire.systemMessage(0).contains("JSON Schema"), "which the exact way did not need")
    expectEqual(endpoint.mode, .jsonObject, "the way that worked is remembered")

    _ = try? await ask(endpoint)
    expectEqual(wire.requests.count, 3, "the next request does not try the refused way again")
    expectEqual((wire.body(2)["response_format"] as? [String: Any])?["type"] as? String, "json_object", "it starts where the last ended")
}

@MainActor
private func testStepsDownToThePromptAlone() async {
    let wire = Wire()
    wire.replies = [.http(422, "{}"), .http(400, "{}"), .http(200, completion(goodAnswer))]
    let endpoint = backend(wire)
    let answer = try? await ask(endpoint)
    expectEqual(answer?.cause, "no such column", "the third way answers")
    expect(wire.body(2)["response_format"] == nil, "with no response_format at all")
    expect(wire.systemMessage(2).contains("JSON Schema"), "and the schema in the instructions")
    expectEqual(endpoint.mode, .promptOnly, "remembered")
}

@MainActor
private func testARefusalOfEveryWayIsAnError() async {
    let wire = Wire()
    wire.replies = [.http(400, "{}"), .http(400, "{}"), .http(400, "{}")]
    let endpoint = backend(wire)
    do {
        _ = try await ask(endpoint)
        expect(false, "three refusals must throw")
    } catch {
        expectEqual(error as? IntelligenceEndpointError, .httpStatus(400), "the last refusal is the error")
    }
    expectEqual(wire.requests.count, 3, "each way is tried once")
    expectEqual(endpoint.mode, .jsonSchema, "a way that never worked is not remembered: the 400 may have meant something else")
}

@MainActor
private func testAFailureDoesNotChangeTheMode() async {
    let wire = Wire()
    wire.replies = [.http(400, "{}"), .http(401, "{}")]
    let endpoint = backend(wire)
    _ = try? await ask(endpoint)
    expectEqual(endpoint.mode, .jsonSchema, "stepping down and then failing keeps the exact way for next time")
}

@MainActor
private func testRunTimeSchema() async {
    let table = DynamicGenerationSchema(name: "TableName", anyOf: ["sales.orders", "sales.customers"])
    let root = DynamicGenerationSchema(name: "TablePick", properties: [
        .init(name: "reason", description: "why", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "tables", schema: DynamicGenerationSchema(arrayOf: table, minimumElements: 1, maximumElements: 6)),
    ])
    guard let schema = try? GenerationSchema(root: root, dependencies: []) else {
        expect(false, "the pick schema must build")
        return
    }
    let wire = Wire()
    wire.replies = [.http(200, completion(#"{"reason":"r","tables":["sales.orders"]}"#))]
    let content = try? await backend(wire).respond(instructions: "I", prompt: "P", schema: schema, sampling: .greedy)
    let tables = try? content?.value([String].self, forProperty: "tables")
    expectEqual(tables ?? [], ["sales.orders"], "a run-time schema's answer is read by property")
    let format = wire.body(0)["response_format"] as? [String: Any]
    let sent = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    let items = ((sent?["properties"] as? [String: Any])?["tables"] as? [String: Any])?["items"] as? [String: Any]
    expectEqual(items?["enum"] as? [String] ?? [], ["sales.orders", "sales.customers"], "the allowed names go out as an enum")
}

/// Fields in the order the answer type declares them, which is the order an
/// endpoint that holds its answer to the schema will write them in.
@Generable
private struct Ordered {
    var zebra: String
    var mango: String
    var apple: String
}

/// Where each of `names` first appears in `text` as a JSON key, in order of
/// appearance.
private func keyOrder(_ names: [String], in text: String) -> [String] {
    names.compactMap { name in text.range(of: "\"\(name)\":").map { (name, $0.lowerBound) } }
        .sorted { $0.1 < $1.1 }.map(\.0)
}

@MainActor
private func testSchemaKeepsTheDeclaredOrder() async {
    let wire = Wire()
    wire.replies = [.http(200, completion(#"{"zebra":"z","mango":"m","apple":"a"}"#))]
    let answer = try? await backend(wire).respond(instructions: "I", prompt: "P", generating: Ordered.self, sampling: .standard)
    expectEqual(answer?.apple, "a", "order: the answer is decoded")
    let sent = String(decoding: wire.requests.first?.httpBody ?? Data(), as: UTF8.self)
    expectEqual(keyOrder(["zebra", "mango", "apple"], in: sent), ["zebra", "mango", "apple"],
                "order: the fields go out as declared, not sorted")
    expect((try? JSONSerialization.jsonObject(with: Data(sent.utf8))) != nil, "order: and the body is still one JSON object")
    let schema = ((wire.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    expectEqual(Set((schema?["properties"] as? [String: Any])?.keys.map { $0 } ?? []), ["zebra", "mango", "apple"],
                "order: every field is there")
    expect(!sent.contains("x-order") && !sent.contains("PHAROS-ANSWER-SCHEMA"), "order: no keyword of ours and no placeholder goes out")

    // The plainer ways write the schema into the instructions: same order.
    let plain = Wire()
    plain.replies = [.http(400, "{}"), .http(200, completion(#"{"zebra":"z","mango":"m","apple":"a"}"#))]
    _ = try? await backend(plain).respond(instructions: "I", prompt: "P", generating: Ordered.self, sampling: .standard)
    expectEqual(keyOrder(["zebra", "mango", "apple"], in: plain.systemMessage(1)), ["zebra", "mango", "apple"],
                "order: the schema in the instructions is in declared order too")

    // A prompt that spells the placeholder cannot stand in for the schema.
    let tricky = Wire()
    tricky.replies = [.http(200, completion(#"{"zebra":"z","mango":"m","apple":"a"}"#))]
    let hostile = #""schema":"@@PHAROS-ANSWER-SCHEMA@@""#
    _ = try? await backend(tricky).respond(instructions: hostile, prompt: hostile, generating: Ordered.self, sampling: .standard)
    let messages = tricky.body(0)["messages"] as? [[String: String]] ?? []
    expectEqual(messages.map { $0["content"] ?? "" }, [hostile, hostile], "order: instructions and prompt arrive as written")
    let stillThere = ((tricky.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    expectEqual(stillThere?["type"] as? String, "object", "order: and the schema is where it belongs")
}

/// A free-text field is given a length the endpoint can enforce, so a model
/// that starts repeating itself inside a string is stopped there.
@MainActor
private func testFreeTextIsGivenALimit() async {
    let table = DynamicGenerationSchema(name: "TableName", anyOf: ["sales.orders", "sales.customers"])
    let root = DynamicGenerationSchema(name: "TablePick", properties: [
        .init(name: "reason", description: "why", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "tables", schema: DynamicGenerationSchema(arrayOf: table, minimumElements: 1, maximumElements: 6)),
    ])
    guard let schema = try? GenerationSchema(root: root, dependencies: []) else {
        expect(false, "the pick schema must build")
        return
    }
    let wire = Wire()
    wire.replies = [.http(200, completion(#"{"reason":"r","tables":["sales.orders"]}"#))]
    _ = try? await backend(wire).respond(instructions: "I", prompt: "P", schema: schema, sampling: .greedy)
    let sent = ((wire.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    let properties = sent?["properties"] as? [String: Any]
    expectEqual((properties?["reason"] as? [String: Any])?["maxLength"] as? Int, EndpointIntelligenceBackend.textLimit,
                "limit: a free-text field is held to a length")
    let items = (properties?["tables"] as? [String: Any])?["items"] as? [String: Any]
    expect(items?["maxLength"] == nil, "limit: a name held to a list needs none")
    expect((properties?["tables"] as? [String: Any])?["maxLength"] == nil, "limit: and an array is not a string")

    // The typed answers get it too, optional fields included.
    let typed = Wire()
    typed.replies = [.http(200, completion(goodAnswer))]
    _ = try? await ask(backend(typed))
    let typedSchema = ((typed.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    let cause = (typedSchema?["properties"] as? [String: Any])?["cause"] as? [String: Any]
    expectEqual(cause?["maxLength"] as? Int, EndpointIntelligenceBackend.textLimit, "limit: a typed answer's text field has it")
    let sentText = String(decoding: typed.requests.first?.httpBody ?? Data(), as: UTF8.self)
    expect(sentText.components(separatedBy: "\"maxLength\"").count - 1 >= 2, "limit: every free-text field, at every depth: \(sentText)")

    // A feature can say that a field is a line, and that a list holds names.
    let use = DynamicGenerationSchema(name: "TableUse", properties: [
        .init(name: "table", schema: DynamicGenerationSchema(name: "TableName", anyOf: ["sales.orders"])),
        .init(name: "columns", schema: DynamicGenerationSchema(
            arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 12)),
    ])
    let reading = DynamicGenerationSchema(name: "TableReading", properties: [
        .init(name: "plan", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "notes", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "tables", schema: DynamicGenerationSchema(arrayOf: use, minimumElements: 0, maximumElements: 1)),
    ])
    guard let nested = try? GenerationSchema(root: reading, dependencies: []) else {
        expect(false, "the reading schema must build")
        return
    }
    let named = Wire()
    named.replies = [.http(200, completion(#"{"plan":"p","notes":"n","tables":[]}"#))]
    _ = try? await backend(named).respond(
        instructions: "I", prompt: "P", schema: nested, textLimits: ["plan": 300, "columns": 128], sampling: .greedy)
    let namedSchema = ((named.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    let namedProperties = namedSchema?["properties"] as? [String: Any]
    expectEqual((namedProperties?["plan"] as? [String: Any])?["maxLength"] as? Int, 300, "limit: a field the feature names gets its own")
    expectEqual((namedProperties?["notes"] as? [String: Any])?["maxLength"] as? Int, EndpointIntelligenceBackend.textLimit,
                "limit: one it does not name gets the general one")
    let definition = (namedSchema?["$defs"] as? [String: Any])?["TableUse"] as? [String: Any]
    let columns = (definition?["properties"] as? [String: Any])?["columns"] as? [String: Any]
    expectEqual((columns?["items"] as? [String: Any])?["maxLength"] as? Int, 128, "limit: a list's strings take the list's limit, inside a definition too")
}

/// The reading step's answer: an object inside an array, which
/// FoundationModels encodes as a definition and a reference to it.
@MainActor
private func testNestedSchemaKeepsItsOrderAndItsDefinitions() async {
    let use = DynamicGenerationSchema(name: "TableUse", properties: [
        .init(name: "table", schema: DynamicGenerationSchema(name: "TableName", anyOf: ["sales.orders", "sales.customers"])),
        .init(name: "columns", schema: DynamicGenerationSchema(
            arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 12)),
    ])
    let root = DynamicGenerationSchema(name: "TableReading", properties: [
        .init(name: "plan", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "tables", schema: DynamicGenerationSchema(arrayOf: use, minimumElements: 0, maximumElements: 2)),
    ])
    guard let schema = try? GenerationSchema(root: root, dependencies: []) else {
        expect(false, "the reading schema must build")
        return
    }
    let wire = Wire()
    wire.replies = [.http(200, completion(#"{"plan":"p","tables":[{"table":"sales.orders","columns":["id","placed_at"]}]}"#))]
    let content = try? await backend(wire).respond(instructions: "I", prompt: "P", schema: schema, sampling: .greedy)
    let uses = (try? content?.value([GeneratedContent].self, forProperty: "tables")) ?? []
    expectEqual(uses.count, 1, "nested: the array of objects is read")
    expectEqual((try? uses.first?.value(String.self, forProperty: "table")) ?? "", "sales.orders", "nested: an object's field")
    expectEqual((try? uses.first?.value([String].self, forProperty: "columns")) ?? [], ["id", "placed_at"], "nested: and its list")

    let sent = String(decoding: wire.requests.first?.httpBody ?? Data(), as: UTF8.self)
    expectEqual(keyOrder(["table", "columns"], in: sent), ["table", "columns"],
                "nested: the table is named before its columns are listed")
    let body = ((wire.body(0)["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    let definition = (body?["$defs"] as? [String: Any])?["TableUse"] as? [String: Any]
    expectEqual(definition?["type"] as? String, "object", "nested: the definition goes out")
    expect(definition?["title"] == nil && definition?["x-order"] == nil, "nested: without our keywords, at depth too")
    let items = ((body?["properties"] as? [String: Any])?["tables"] as? [String: Any])?["items"] as? [String: Any]
    expectEqual(items?["$ref"] as? String, "#/$defs/TableUse", "nested: and the reference to it")
    expectEqual(((definition?["properties"] as? [String: Any])?["table"] as? [String: Any])?["enum"] as? [String] ?? [],
                ["sales.orders", "sales.customers"], "nested: the names are still an enum")
}

@MainActor
private func testStreamDeliversTheWholeAnswerOnce() async {
    let wire = Wire()
    wire.replies = [.http(200, completion(goodAnswer))]
    var snapshots: [Explanation.PartiallyGenerated] = []
    do {
        for try await snapshot in backend(wire).streamResponse(instructions: "I", prompt: "P", generating: Explanation.self) {
            snapshots.append(snapshot)
        }
    } catch {
        expect(false, "the stream threw \(error)")
    }
    expectEqual(snapshots.count, 1, "one snapshot: the whole answer")
    expectEqual(snapshots.first?.cause, "no such column", "with its fields filled")
    expectEqual(snapshots.first?.fixes ?? [], ["check the name"], "all of them")

    let failing = Wire()
    failing.replies = [.http(429, "{}")]
    do {
        for try await _ in backend(failing).streamResponse(instructions: "I", prompt: "P", generating: Explanation.self) {}
        expect(false, "a failed stream must throw")
    } catch {
        expectEqual(error as? IntelligenceEndpointError, .rateLimited, "the stream carries the endpoint's error")
    }
}

@MainActor
private func testWindowAndCounting() async {
    let endpoint = backend(Wire())
    expectEqual(endpoint.contextSize, 32768, "the window is the configured one")
    do {
        _ = try await endpoint.tokenCount(instructions: "I", prompt: "P", schema: Explanation.generationSchema)
        expect(false, "an endpoint cannot count tokens")
    } catch {
        expect(error is IntelligenceBackendError, "so the caller keeps its estimate")
    }
}

private func testErrorKinds() {
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.rateLimited), .rateLimited, "kind: rate limit")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.tooLong), .contextSizeExceeded, "kind: too long")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.refused), .refusal, "kind: refusal")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.unexpectedAnswer), .decodingFailure, "kind: bad answer")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.timedOut), .timeout, "kind: timeout")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.keyRefused).name, "endpoint.keyRefused", "kind: key")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.unreachable("the host name")).name, "endpoint.unreachable",
                "kind: the reason is not in the log name")
    expectEqual(ModelErrorKind.of(IntelligenceEndpointError.modelNotFound("my-model")).name, "endpoint.modelNotFound",
                "kind: the model name is not in the log name")
}

func runTests() {
    Task { @MainActor in
        await testRequestShape()
        await testGreedyAndKeyless()
        await testFieldNamedTitleIsKept()
        await testMessyAnswers()
        await testBadAnswers()
        await testStatuses()
        await testTransportFailures()
        await testStepsDownWhenTheSchemaIsRefused()
        await testStepsDownToThePromptAlone()
        await testARefusalOfEveryWayIsAnError()
        await testAFailureDoesNotChangeTheMode()
        await testRunTimeSchema()
        await testSchemaKeepsTheDeclaredOrder()
        await testFreeTextIsGivenALimit()
        await testNestedSchemaKeepsItsOrderAndItsDefinitions()
        await testStreamDeliversTheWholeAnswerOnce()
        await testWindowAndCounting()
        testErrorKinds()
        print("\(passes) passed, \(failures) failed")
        exit(failures > 0 ? 1 : 0)
    }
    dispatchMain()
}
