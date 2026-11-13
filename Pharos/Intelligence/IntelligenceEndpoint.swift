import Foundation

/// The custom AI endpoint as the user typed it: is the address usable, and
/// does anything answer there.
///
/// Foundation only, so `scripts/test-intelligence-endpoint.sh` compiles it
/// alone. The settings it reads are passed in; the API key is passed in and
/// never kept.
enum IntelligenceEndpoint {

    // MARK: - The address

    /// Why an address cannot be used.
    enum Problem: Error, Equatable {
        case empty
        case notAnAddress
        /// Something other than http or https.
        case unsupportedScheme
        /// Plain http to a host that is not this Mac. The prompt carries the
        /// user's schema and SQL, and the request carries the API key.
        case notEncrypted
        /// `user:password@host`. The address is stored in the settings file
        /// in plain text; a secret belongs in the API key field.
        case carriesCredentials
        /// A `?query` or `#fragment`, which no API root has.
        case carriesQuery

        var message: String {
            switch self {
            case .empty:
                return String(localized: "Enter the endpoint's address.")
            case .notAnAddress:
                return String(localized: "This is not a web address. It should look like https://api.example.com/v1.")
            case .unsupportedScheme:
                return String(localized: "The address must start with https://.")
            case .notEncrypted:
                return String(localized: "Use https://. Plain http:// is allowed only for an endpoint on this Mac, such as http://localhost:11434/v1.")
            case .carriesCredentials:
                return String(localized: "Remove the user name and password from the address. Put the secret in the API key field, which is kept in the Keychain.")
            case .carriesQuery:
                return String(localized: "Remove everything from the ? or # onwards.")
            }
        }
    }

    /// The API root for `text`, or why it cannot be one.
    ///
    /// The result has no trailing slash, so a path is appended the same way
    /// whichever form the user typed.
    static func baseURL(from text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return .failure(.notAnAddress)
        }
        guard scheme == "https" || scheme == "http" else { return .failure(.unsupportedScheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.notAnAddress) }
        guard components.user == nil, components.password == nil else { return .failure(.carriesCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.carriesQuery) }
        guard scheme == "https" || isLoopback(host) else { return .failure(.notEncrypted) }

        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return .failure(.notAnAddress) }
        return .success(url)
    }

    /// Whether `host` is this Mac: `localhost`, a name under `.localhost`,
    /// 127.0.0.0/8 or `::1`. Decided from the name alone, never by a lookup:
    /// a name that merely resolves to 127.0.0.1 today is not a promise.
    static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name == "::1" { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
                && (UInt8(part) != nil)
        }
    }

    /// Where the answers are written, for a label: "this Mac" or the host.
    static func isOnThisMac(_ base: URL) -> Bool {
        base.host.map(isLoopback) ?? false
    }

    /// The host of an endpoint, as it is shown and compared: lowercased.
    static func host(of base: URL) -> String {
        (base.host ?? "").lowercased()
    }

    /// The host the user must agree to before anything is sent, or nil when
    /// nothing needs agreeing: the endpoint is on this Mac, or they have
    /// already agreed to exactly this host.
    ///
    /// Agreement is to a host, not to "a custom endpoint". Changing the
    /// address to another machine is a new destination for the user's SQL
    /// and schema, and is asked about again.
    static func hostNeedingPermission(base: URL, allowedHost: String) -> String? {
        guard !isOnThisMac(base) else { return nil }
        let host = host(of: base)
        return host == allowedHost.lowercased() ? nil : host
    }

    // MARK: - Does anything answer

    /// What asking the endpoint for its models showed.
    enum CheckOutcome: Equatable {
        /// It answered, and lists the configured model (or none was named).
        case ready(models: Int)
        /// It answered, but does not list the configured model.
        case modelNotListed(model: String, models: Int)
        /// 401 or 403.
        case keyRefused
        /// 404: nothing at `<address>/models`.
        case noAPIHere
        case httpStatus(Int)
        /// 200, but not a list of models.
        case notAModelList
        /// Sent to another address, which Pharos does not follow.
        case redirected
        /// No answer at all. The string is the system's own sentence.
        case unreachable(String)

        var isSuccess: Bool {
            if case .ready = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .ready(let models):
                return String(localized: "Connected. The endpoint lists \(models) models.")
            case .modelNotListed(let model, let models):
                return String(localized: "Connected, but \u{201C}\(model)\u{201D} is not among the \(models) models the endpoint lists.")
            case .keyRefused:
                return String(localized: "The endpoint refused the API key.")
            case .noAPIHere:
                return String(localized: "Nothing answers at this address. Most endpoints end in /v1.")
            case .httpStatus(let status):
                return String(localized: "The endpoint answered with an error (HTTP \(status)).")
            case .notAModelList:
                return String(localized: "Something answered, but not with a list of models. Check the address.")
            case .redirected:
                return String(localized: "The endpoint sent Pharos to another address. Enter the address it finally answers at.")
            case .unreachable(let reason):
                return String(localized: "The endpoint could not be reached. \(reason)")
            }
        }
    }

    /// `GET <base>/models`, the one request every OpenAI-compatible endpoint
    /// answers without being asked to generate anything. It carries the API
    /// key and nothing of the user's.
    static func modelsRequest(base: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// What a check found: the outcome, and the names the endpoint listed.
    struct CheckResult: Equatable {
        let outcome: CheckOutcome
        /// The endpoint's model names, sorted for a list to pick from. Empty
        /// unless it answered with one.
        let models: [String]
    }

    /// Read the answer to `modelsRequest`.
    static func outcome(status: Int, body: Data, model: String) -> CheckOutcome {
        result(status: status, body: body, model: model).outcome
    }

    /// Read the answer to `modelsRequest`, keeping the names it listed.
    static func result(status: Int, body: Data, model: String) -> CheckResult {
        switch status {
        case 200..<300:
            guard let ids = modelIDs(in: body) else { return CheckResult(outcome: .notAModelList, models: []) }
            // Each name once, in an order a person can scan. An endpoint
            // lists them in its own order, which for a large one is none.
            let names = Array(Set(ids.filter { !$0.isEmpty }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let wanted = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted.isEmpty || ids.contains(wanted) {
                return CheckResult(outcome: .ready(models: ids.count), models: names)
            }
            return CheckResult(outcome: .modelNotListed(model: wanted, models: ids.count), models: names)
        case 300..<400: return CheckResult(outcome: .redirected, models: [])
        case 401, 403: return CheckResult(outcome: .keyRefused, models: [])
        case 404: return CheckResult(outcome: .noAPIHere, models: [])
        default: return CheckResult(outcome: .httpStatus(status), models: [])
        }
    }

    /// The ids in `{"data": [{"id": "..."}]}`, or nil when the body is not
    /// that shape.
    static func modelIDs(in body: Data) -> [String]? {
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return (try? JSONDecoder().decode(List.self, from: body))?.data.map(\.id)
    }

    /// A session for talking to the endpoint: no cookies, no cache, no
    /// shared credentials, and no redirects. A redirect would carry the API
    /// key, and the prompt, to a host the user did not name.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Ask the endpoint for its models.
    static func check(base: URL, model: String, key: String?) async -> CheckResult {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (body, response) = try await session.data(for: modelsRequest(base: base, key: key))
            guard let http = response as? HTTPURLResponse else { return CheckResult(outcome: .notAModelList, models: []) }
            return result(status: http.statusCode, body: body, model: model)
        } catch {
            return CheckResult(outcome: .unreachable(error.localizedDescription), models: [])
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
