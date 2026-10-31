import Foundation

/// A `pharos://duckdb/attach` link, read and checked: the remote DuckDB
/// database it names, and the alias it attaches as.
struct ParsedDuckDBLink: Equatable {
    /// `http` or `https`, with a host and no user or password.
    var databaseURL: URL
    /// A plain DuckDB identifier: lower-case letters, digits and `_`, at most
    /// 63 characters, never one of DuckDB's own database names.
    var alias: String

    /// For the confirmation alert: where the file is.
    var host: String {
        guard let host = databaseURL.host else { return "" }
        if let port = databaseURL.port { return "\(host):\(port)" }
        return host
    }

    /// For the confirmation alert: the file's last path part.
    var fileName: String { databaseURL.lastPathComponent }
}

/// Reads `pharos://duckdb/attach?url=<http(s) URL>&name=<alias>`.
///
/// A web page (the Recon to DuckDB app, for example) uses this link to show
/// a DuckDB file it serves over HTTP in Pharos without a download. DuckDB's
/// httpfs reads the file in place with Range requests.
///
/// Foundation only, so `scripts/test-duckdb-link-parser.sh` tests it without
/// the app. Nothing here connects or runs SQL: the caller asks the user first,
/// and pharos-core (`duck_attach::remote_attach_sql`) checks the URL and alias
/// again before it builds the ATTACH.
enum DuckDBLinkParser {

    static let scheme = "pharos"

    static func parse(_ url: URL) -> ParsedDuckDBLink? {
        parse(string: url.absoluteString)
    }

    static func parse(string: String) -> ParsedDuckDBLink? {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "duckdb",
              components.path == "/attach" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value
        }
        guard let raw = query["url"], let databaseURL = remoteDatabaseURL(raw) else { return nil }
        let name = query["name"].flatMap { $0.isEmpty ? nil : $0 }
            ?? databaseURL.deletingPathExtension().lastPathComponent
        return ParsedDuckDBLink(databaseURL: databaseURL, alias: alias(from: name))
    }

    /// The `url` parameter, if it is one DuckDB may attach: `http` or
    /// `https`, a host, no user or password (a secret does not belong in a
    /// link), and no control characters (the URL goes into SQL text).
    static func remoteDatabaseURL(_ raw: String) -> URL? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// `name` as a DuckDB identifier: lower-cased, each run of other
    /// characters turned into one `_`. `db_` goes in front of a name that
    /// would start with a digit, be empty, or be one of DuckDB's own
    /// database names.
    static func alias(from name: String) -> String {
        var out = ""
        for ch in name.trimmingCharacters(in: .whitespaces).lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.hasSuffix("_") {
                out.append("_")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if out.isEmpty || out.first!.isNumber || reserved.contains(out) {
            out = out.isEmpty ? "db" : "db_" + out
        }
        return String(out.prefix(63))
    }

    private static let reserved: Set<String> = ["memory", "system", "temp", "main"]
}
