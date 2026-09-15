import Foundation

/// The parts of a `postgres://` / `postgresql://` connection link that Pharos
/// can put into the Connections form.
///
/// Foundation only, and deliberately free of `ConnectionConfig`: the mapping to
/// the app's model lives at the call site (`ConnectionsManagerWindowController`)
/// so this type — the part with all the parsing rules in it — can be unit
/// tested on its own. `sslMode` is this file's own three-case enum for the same
/// reason; the call site switches over it exhaustively, so a new case cannot be
/// dropped silently.
struct ParsedConnectionURL: Equatable {

    /// The three modes Pharos offers. libpq's six `sslmode` values are reduced
    /// to these by `ConnectionURLParser`.
    enum SSLMode: String {
        case disable
        case prefer
        case require
    }

    /// Never empty. `localhost` when the link named no host but was otherwise
    /// usable (a database or a user), which is what libpq would fall back to.
    var host: String
    /// `nil` when the link named no port; the caller supplies 5432.
    var port: UInt16?
    var user: String?
    var password: String?
    var database: String?
    var sslMode: SSLMode?
    /// `true` when the link carried a password. The form shows a note saying so,
    /// because a password arriving from a link is worth pointing at.
    var passwordWasInURL: Bool

    /// `user@host/database`, dropping the halves the link did not carry, so a
    /// bare `postgresql://localhost` is named `localhost`.
    var suggestedName: String {
        var name = ""
        if let user, !user.isEmpty { name += "\(user)@" }
        name += host
        if let database, !database.isEmpty { name += "/\(database)" }
        return name
    }
}

/// Reads a PostgreSQL connection URI into the fields of the Connections form.
///
/// The shape is libpq's (§34.1.1.2 of the PostgreSQL manual):
/// `postgresql://user:password@host:port/dbname?param=value`. Everything is
/// optional, and every part may instead arrive as a query parameter — libpq
/// accepts `postgresql:///db?host=/tmp&user=x`, and so does this.
///
/// Nothing here connects, saves or reads the Keychain: the result is form text.
enum ConnectionURLParser {

    /// The schemes libpq defines. Compared case-insensitively.
    static let schemes: [String] = ["postgres", "postgresql"]

    static func parse(_ url: URL) -> ParsedConnectionURL? {
        parse(string: url.absoluteString)
    }

    /// The string form exists because `URL(string:)` REJECTS a multi-host link
    /// (`postgresql://h1:5432,h2:5432/db`) outright — the comma makes the port
    /// unparseable — so a test could not even build the `URL` to hand over.
    /// AppKit's own URL, built by CFURL from the Apple event, is laxer and does
    /// arrive, which is why the repair below is not hypothetical.
    static func parse(string: String) -> ParsedConnectionURL? {
        guard let components = components(from: string) else { return nil }
        guard let scheme = components.scheme,
              schemes.contains(scheme.lowercased()) else { return nil }

        let query = queryParameters(components)

        // Authority first, query parameter second — that is libpq's precedence,
        // and it is what makes `postgresql:///db?host=/tmp` work.
        let authorityHost = unbracketed(components.host)
        let host = nonEmpty(authorityHost) ?? nonEmpty(query["host"])
        let port = components.port.flatMap { UInt16(exactly: $0) }
            ?? nonEmpty(query["port"]).flatMap { UInt16($0) }
        let user = nonEmpty(components.user) ?? nonEmpty(query["user"])
        let password = nonEmpty(components.password) ?? nonEmpty(query["password"])

        // `URLComponents.path` is percent-decoded already, so a database called
        // `my db` arrives whole.
        let pathDatabase = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path
        let database = nonEmpty(pathDatabase) ?? nonEmpty(query["dbname"])

        // A link that names no host, no database and no user has nothing to
        // pre-fill and is reported as unreadable rather than opening an empty
        // form. `postgresql://` is the case this rejects.
        guard host != nil || database != nil || user != nil else { return nil }

        return ParsedConnectionURL(
            host: host ?? "localhost",
            port: port,
            user: user,
            password: password,
            database: database,
            sslMode: sslMode(from: query["sslmode"]),
            passwordWasInURL: password != nil
        )
    }

    // MARK: - Pieces

    /// libpq's six `sslmode` values against the three Pharos offers. `allow`
    /// means "plain text unless the server insists", which is what `prefer`
    /// does here; both `verify-` modes are `require` plus checks Pharos does not
    /// expose, so they map to `require` rather than being dropped. An
    /// unrecognised value returns `nil`, leaving the form's own default alone.
    static func sslMode(from raw: String?) -> ParsedConnectionURL.SSLMode? {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "disable":                         return .disable
        case "allow", "prefer":                 return .prefer
        case "require", "verify-ca", "verify-full": return .require
        default:                                return nil
        }
    }

    /// `URLComponents` for `string`, repairing the one shape it refuses that
    /// libpq accepts: a comma-separated host list. Only the FIRST host is kept —
    /// the form holds one server.
    private static func components(from string: String) -> URLComponents? {
        if let components = URLComponents(string: string) { return components }

        guard let separator = string.range(of: "://") else { return nil }
        let head = String(string[..<separator.upperBound])
        let rest = String(string[separator.upperBound...])

        // The authority ends at the first `/`, `?` or `#`.
        let endIndex = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = String(rest[..<endIndex])
        let tail = String(rest[endIndex...])

        // Split at the LAST `@`: a password may hold a comma of its own, and
        // only the host-port list after the userinfo is a list.
        let userinfo: String
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[...at])
            authority = String(authority[authority.index(after: at)...])
        } else {
            userinfo = ""
        }
        guard let comma = authority.firstIndex(of: ",") else { return nil }
        authority = String(authority[..<comma])

        return URLComponents(string: head + userinfo + authority + tail)
    }

    /// The query as a dictionary, lower-cased keys, percent-decoded values.
    /// A repeated key keeps the FIRST value, matching libpq, and a parameter
    /// this app has no field for is ignored.
    private static func queryParameters(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            guard result[key] == nil, let value = item.value else { continue }
            result[key] = value
        }
        return result
    }

    /// `[::1]` as `::1`. `URLComponents.host` keeps the brackets an IPv6
    /// literal needs in a URL; libpq — and the form — want the address itself.
    private static func unbracketed(_ host: String?) -> String? {
        guard let host, host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
