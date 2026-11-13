import Foundation

// Tests for `IntelligenceEndpoint`: which addresses a custom AI endpoint may
// have, and how the answer to "list your models" is read. Run by
// scripts/test-intelligence-endpoint.sh. No request is made.

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

private func address(_ text: String) -> String? {
    if case .success(let url) = IntelligenceEndpoint.baseURL(from: text) { return url.absoluteString }
    return nil
}

private func problem(_ text: String) -> IntelligenceEndpoint.Problem? {
    if case .failure(let problem) = IntelligenceEndpoint.baseURL(from: text) { return problem }
    return nil
}

private func testAcceptedAddresses() {
    expectEqual(address("https://api.example.com/v1"), "https://api.example.com/v1", "https is accepted as typed")
    expectEqual(address("  https://api.example.com/v1/  \n"), "https://api.example.com/v1", "spaces and a trailing slash go")
    expectEqual(address("https://api.example.com/v1///"), "https://api.example.com/v1", "every trailing slash goes")
    expectEqual(address("HTTPS://api.example.com"), "https://api.example.com", "the scheme is lowercased; no path is fine")
    expectEqual(address("https://gateway.example.com:8443/llm/v1"), "https://gateway.example.com:8443/llm/v1", "a port and a deeper path are kept")
    expectEqual(address("http://localhost:11434/v1"), "http://localhost:11434/v1", "http to localhost")
    expectEqual(address("http://127.0.0.1:1234/v1"), "http://127.0.0.1:1234/v1", "http to 127.0.0.1")
    expectEqual(address("http://[::1]:8080/v1"), "http://[::1]:8080/v1", "http to ::1")
    expectEqual(address("http://ollama.localhost/v1"), "http://ollama.localhost/v1", "http to a .localhost name")
}

private func testRefusedAddresses() {
    expectEqual(problem(""), .empty, "nothing typed")
    expectEqual(problem("   "), .empty, "only spaces")
    expectEqual(problem("api.example.com/v1"), .notAnAddress, "no scheme")
    expectEqual(problem("https://"), .notAnAddress, "no host")
    expectEqual(problem("ftp://example.com"), .unsupportedScheme, "not http")
    expectEqual(problem("file:///etc/passwd"), .unsupportedScheme, "a file is not an endpoint")
    expectEqual(problem("http://api.example.com/v1"), .notEncrypted, "http to another machine")
    expectEqual(problem("http://192.168.1.20:11434/v1"), .notEncrypted, "http on the local network is still another machine")
    expectEqual(problem("http://localhost.example.com/v1"), .notEncrypted, "a name that only starts with localhost")
    expectEqual(problem("http://127.0.0.1.example.com/v1"), .notEncrypted, "a name that only starts with 127.0.0.1")
    expectEqual(problem("https://user:secret@api.example.com/v1"), .carriesCredentials, "a password in the address")
    expectEqual(problem("https://user@api.example.com/v1"), .carriesCredentials, "a user name in the address")
    expectEqual(problem("https://api.example.com/v1?key=abc"), .carriesQuery, "a key in the query")
    expectEqual(problem("https://api.example.com/v1#x"), .carriesQuery, "a fragment")
    for p in [IntelligenceEndpoint.Problem.empty, .notAnAddress, .unsupportedScheme, .notEncrypted, .carriesCredentials, .carriesQuery] {
        expect(!p.message.isEmpty, "\(p) has a sentence for the user")
    }
}

private func testLoopback() {
    for host in ["localhost", "LOCALHOST", "localhost.", "a.b.localhost", "127.0.0.1", "127.255.0.9", "::1", "[::1]"] {
        expect(IntelligenceEndpoint.isLoopback(host), "\(host) is this Mac")
    }
    for host in ["example.com", "localhost.example.com", "notlocalhost", "128.0.0.1", "127.0.0", "127.0.0.1.5",
                 "127.0.0.256", "127.a.0.1", "0.0.0.0", "192.168.0.1", "::2", ""] {
        expect(!IntelligenceEndpoint.isLoopback(host), "\(host) is not this Mac")
    }
    expect(IntelligenceEndpoint.isOnThisMac(URL(string: "http://localhost:11434/v1")!), "a localhost endpoint is on this Mac")
    expect(!IntelligenceEndpoint.isOnThisMac(URL(string: "https://api.example.com/v1")!), "a remote endpoint is not")
}

private func testPermission() {
    func needs(_ address: String, allowed: String) -> String? {
        IntelligenceEndpoint.hostNeedingPermission(base: URL(string: address)!, allowedHost: allowed)
    }
    expectEqual(needs("https://api.example.com/v1", allowed: ""), "api.example.com", "another machine needs agreeing to")
    expectEqual(needs("https://api.example.com/v1", allowed: "api.example.com"), nil, "once agreed, it does not")
    expectEqual(needs("https://API.Example.com/v1", allowed: "api.example.com"), nil, "case does not make a new host")
    expectEqual(needs("https://api.example.com:8443/other", allowed: "api.example.com"), nil, "a port or path on the same host is the same host")
    expectEqual(needs("https://evil.example.com/v1", allowed: "api.example.com"), "evil.example.com", "another host is asked about again")
    expectEqual(needs("https://api.example.com.evil.net/v1", allowed: "api.example.com"), "api.example.com.evil.net", "a longer name is another host")
    expectEqual(needs("http://localhost:11434/v1", allowed: ""), nil, "this Mac needs none")
    expectEqual(needs("http://127.0.0.1:1234/v1", allowed: ""), nil, "nor does 127.0.0.1")
    expectEqual(needs("https://192.168.1.20/v1", allowed: ""), "192.168.1.20", "the local network is another machine")
}

private func testModelsRequest() {
    let base = URL(string: "https://api.example.com/v1")!
    let request = IntelligenceEndpoint.modelsRequest(base: base, key: "sk-test")
    expectEqual(request.url?.absoluteString, "https://api.example.com/v1/models", "the list lives under the root")
    expectEqual(request.httpMethod, "GET", "a read")
    expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test", "the key is a bearer token")
    expect(request.httpBody == nil, "nothing of the user's is sent")
    expect(request.url?.query == nil, "the key is never in the address")

    let keyless = IntelligenceEndpoint.modelsRequest(base: URL(string: "http://localhost:11434/v1")!, key: nil)
    expect(keyless.value(forHTTPHeaderField: "Authorization") == nil, "no key, no header")
    let empty = IntelligenceEndpoint.modelsRequest(base: base, key: "")
    expect(empty.value(forHTTPHeaderField: "Authorization") == nil, "an empty key sends no header either")
}

private func testOutcomes() {
    let list = Data(#"{"object":"list","data":[{"id":"alpha","object":"model"},{"id":"beta"}]}"#.utf8)
    typealias Outcome = IntelligenceEndpoint.CheckOutcome
    expectEqual(IntelligenceEndpoint.modelIDs(in: list), ["alpha", "beta"], "the ids are read")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: list, model: "beta"), Outcome.ready(models: 2), "a listed model is ready")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: list, model: " beta "), Outcome.ready(models: 2), "spaces round the name do not matter")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: list, model: ""), Outcome.ready(models: 2), "no model named yet still connects")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: list, model: "gamma"),
                Outcome.modelNotListed(model: "gamma", models: 2), "an unlisted model is named")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: Data("<html>".utf8), model: "x"), Outcome.notAModelList, "a web page is not an API")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: Data(#"{"models":[]}"#.utf8), model: "x"), Outcome.notAModelList, "another shape is not a list")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: Data(#"{"data":[]}"#.utf8), model: ""), Outcome.ready(models: 0), "an empty list is still a list")
    expectEqual(IntelligenceEndpoint.outcome(status: 401, body: Data(), model: "x"), Outcome.keyRefused, "401")
    expectEqual(IntelligenceEndpoint.outcome(status: 403, body: Data(), model: "x"), Outcome.keyRefused, "403")
    expectEqual(IntelligenceEndpoint.outcome(status: 404, body: Data(), model: "x"), Outcome.noAPIHere, "404")
    expectEqual(IntelligenceEndpoint.outcome(status: 302, body: Data(), model: "x"), Outcome.redirected, "a redirect is not followed")
    expectEqual(IntelligenceEndpoint.outcome(status: 500, body: list, model: "beta"), Outcome.httpStatus(500), "an error status wins over its body")
    expect(Outcome.ready(models: 1).isSuccess, "ready is the one success")
    expect(!Outcome.modelNotListed(model: "m", models: 1).isSuccess, "an unlisted model is not a success")
    expect(Outcome.modelNotListed(model: "gamma", models: 2).message.contains("gamma"), "the message names the model")
    expect(Outcome.httpStatus(503).message.contains("503"), "the message names the status")
    expect(Outcome.unreachable("The request timed out.").message.contains("timed out"), "the system's reason is passed on")
}

private func testListedModels() {
    let list = Data(#"{"data":[{"id":"zeta"},{"id":"model-10"},{"id":"model-2"},{"id":"Alpha"},{"id":"zeta"},{"id":""}]}"#.utf8)
    let listed = IntelligenceEndpoint.result(status: 200, body: list, model: "zeta")
    expectEqual(listed.models, ["Alpha", "model-2", "model-10", "zeta"],
                "each name once, empty ones dropped, sorted the way a person reads them")
    expectEqual(listed.outcome, .ready(models: 6), "the outcome still counts what the endpoint sent")

    let unlisted = IntelligenceEndpoint.result(status: 200, body: list, model: "gamma")
    expectEqual(unlisted.outcome, .modelNotListed(model: "gamma", models: 6), "an unlisted model is still named")
    expectEqual(unlisted.models.count, 4, "and the list is offered so it can be put right")

    expectEqual(IntelligenceEndpoint.result(status: 401, body: list, model: "zeta").models, [], "a refused key lists nothing")
    expectEqual(IntelligenceEndpoint.result(status: 200, body: Data("<html>".utf8), model: "").models, [], "nor does a web page")
    expectEqual(IntelligenceEndpoint.result(status: 200, body: Data(#"{"data":[]}"#.utf8), model: "").models, [], "an empty list is empty")
    expectEqual(IntelligenceEndpoint.outcome(status: 200, body: list, model: "zeta"), listed.outcome, "outcome(...) is the same reading")
}

private func testSourceNames() {
    let apple = IntelligenceSource(usesEndpoint: false, address: "https://api.example.com/v1", model: "m")
    expectEqual(apple, .apple, "Apple's model, whatever endpoint is filled in beside it")
    expectEqual(apple.generatedBy, "Generated by Apple Intelligence", "apple: the label")
    expectEqual(apple.nameSuggestedBy, "Name suggested by Apple Intelligence", "apple: the tooltip")
    expectEqual(apple.badgeSymbol, "apple.intelligence", "apple: Apple's glyph")
    expectEqual(apple.asking, "Asking the on-device model\u{2026}", "apple: progress")
    expect(!apple.sendsOffThisMac, "apple: nothing leaves")

    let remote = IntelligenceSource(usesEndpoint: true, address: "https://API.example.com/v1", model: " gpt-x ")
    expectEqual(remote, .endpoint(model: "gpt-x", host: "api.example.com", onThisMac: false), "remote: model and host")
    expectEqual(remote.generatedBy, "Generated by gpt-x at api.example.com", "remote: the label names the host")
    expectEqual(remote.nameSuggestedBy, "Name suggested by gpt-x at api.example.com", "remote: the tooltip does too")
    expectEqual(remote.badgeSymbol, "sparkles", "remote: not Apple's glyph")
    expectEqual(remote.asking, "Asking gpt-x at api.example.com\u{2026}", "remote: progress")
    expect(remote.sendsOffThisMac, "remote: it leaves this Mac")
    expect(!remote.generatedBy.contains("Apple"), "remote: Apple is not named")

    let local = IntelligenceSource(usesEndpoint: true, address: "http://localhost:11434/v1", model: "llama")
    expectEqual(local.generatedBy, "Generated by llama on this Mac", "local: the label says it stayed here")
    expectEqual(local.badgeSymbol, "sparkles", "local: still not Apple's glyph")
    expect(!local.sendsOffThisMac, "local: nothing leaves")

    let unnamed = IntelligenceSource(usesEndpoint: true, address: "https://api.example.com/v1", model: "")
    expectEqual(unnamed.generatedBy, "Generated by a custom model at api.example.com", "no model name still names the host")
    let broken = IntelligenceSource(usesEndpoint: true, address: "not an address", model: "m")
    expectEqual(broken.generatedBy, "Generated by m", "an unreadable address is never labelled as Apple's")
    expect(broken.sendsOffThisMac, "and is not assumed to be on this Mac")
}

private func testRowDataConsentWords() {
    let apple = IntelligenceSource.apple.rowDataConsent(what: "The 20 rows on screen")
    expectEqual(apple.title, "Send row data to the on-device model?", "apple: the title as it always was")
    expectEqual(apple.text, "The 20 rows on screen will be read by the model on this Mac. Nothing leaves this Mac.", "apple: the text as it always was")

    let remote = IntelligenceSource.endpoint(model: "gpt-x", host: "api.example.com", onThisMac: false)
        .rowDataConsent(what: "The 20 rows on screen")
    expectEqual(remote.title, "Send row data to api.example.com?", "remote: the title names the host")
    expect(remote.text.contains("leaves this Mac") && !remote.text.contains("Nothing leaves"), "remote: says the rows leave")
    expect(remote.text.contains("gpt-x at api.example.com"), "remote: and where to")

    let local = IntelligenceSource.endpoint(model: "llama", host: "localhost", onThisMac: true)
        .rowDataConsent(what: "The selected cell")
    expect(local.text.contains("Nothing leaves this Mac"), "local: the rows stay")
    expect(local.title.contains("llama"), "local: the model is named")
}

func runTests() {
    testAcceptedAddresses()
    testRefusedAddresses()
    testLoopback()
    testPermission()
    testModelsRequest()
    testOutcomes()
    testListedModels()
    testSourceNames()
    testRowDataConsentWords()
    print("\(passes) passed, \(failures) failed")
    if failures > 0 { exit(1) }
}
