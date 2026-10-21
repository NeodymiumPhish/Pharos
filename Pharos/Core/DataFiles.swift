import Foundation

/// Files DuckDB reads in place: CSV, TSV, JSON, newline-delimited JSON,
/// Parquet and Excel. A drop on a DuckDB card, Query ▸ Insert File
/// Reference…, ⌘O, Finder and New Table from File… all classify a file
/// here, so they agree on what each one is.
///
/// Pure and Foundation-only: `scripts/test-data-files.sh` pins it, and the
/// editor's standalone harnesses compile it with `SQLTextView`.
enum DataFiles {

    enum Kind: Equatable {
        case csv, tsv, json, ndjson, parquet, xlsx
        /// A DuckDB database: opened as a connection, never read here.
        case duckdb
        case sqlite
        /// Any other file.
        case other

        /// DuckDB's reader for this kind; nil when it is not a data file.
        var reader: String? {
            switch self {
            case .csv, .tsv: return "read_csv"
            case .json, .ndjson: return "read_json"
            case .parquet: return "read_parquet"
            case .xlsx: return "read_xlsx"
            case .duckdb, .sqlite, .other: return nil
            }
        }

        /// A file DuckDB reads in place.
        var isData: Bool { reader != nil }
    }

    /// By extension: Parquet has only a dynamic type, and a CSV's type is
    /// `public.text`, so the content type alone cannot tell them apart.
    static func kind(of url: URL) -> Kind {
        guard url.isFileURL else { return .other }
        switch url.pathExtension.lowercased() {
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "json": return .json
        case "ndjson", "jsonl": return .ndjson
        case "parquet", "pq": return .parquet
        case "xlsx": return .xlsx
        case "duckdb", "ddb": return .duckdb
        case "sqlite", "sqlite3": return .sqlite
        default: return .other
        }
    }

    static func isDataFile(_ url: URL) -> Bool { kind(of: url).isData }

    /// The extensions of every data kind, for open panels.
    static let dataExtensions = ["csv", "tsv", "tab", "json", "ndjson", "jsonl", "parquet", "pq", "xlsx"]

    /// A path as a SQL string literal: absolute, single quotes doubled.
    static func literal(_ url: URL) -> String {
        "'" + url.standardizedFileURL.path.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// What a drop (or Insert File Reference…) puts in a card.
    ///
    /// - An empty card gets a whole query: `SELECT * FROM read_csv('<path>')`.
    ///   Several files of one kind are read together, by column name
    ///   (`union_by_name`); Excel files, whose reader takes one file, are
    ///   joined with `UNION ALL BY NAME`.
    /// - A card with text gets the quoted path only — a valid FROM target and
    ///   reader argument — one per line for several.
    /// - Files of different kinds always get quoted paths, one per line.
    static func insertion(for urls: [URL], cardIsEmpty: Bool) -> String {
        let paths = urls.map(literal)
        let kinds = Set(urls.map { kind(of: $0) })
        guard cardIsEmpty, kinds.count == 1, let kind = kinds.first, let reader = kind.reader else {
            return paths.joined(separator: "\n")
        }
        if paths.count == 1 { return "SELECT * FROM \(reader)(\(paths[0]))" }
        if kind == .xlsx {
            return paths.map { "SELECT * FROM \(reader)(\($0))" }.joined(separator: "\nUNION ALL BY NAME\n")
        }
        return "SELECT * FROM \(reader)([\(paths.joined(separator: ", "))], union_by_name = true)"
    }

    /// `CREATE TABLE "schema"."name" AS FROM read_csv('<path>')` for New
    /// Table from File…. Plain CREATE, never OR REPLACE: a name clash gives
    /// DuckDB's own error instead of silently replacing a table.
    /// `nullString`: the Settings NULL literal, passed as `nullstr` to the
    /// CSV reader when it is not empty. `encoding`: DuckDB's name for a CSV
    /// encoding other than UTF-8 ("utf-16", "latin-1").
    static func createTableSQL(for url: URL, schema: String, table: String, nullString: String? = nil,
                               encoding: String? = nil) -> String? {
        let kind = kind(of: url)
        guard let reader = kind.reader else { return nil }
        var arguments = literal(url)
        if kind == .csv || kind == .tsv {
            if let nullString, !nullString.isEmpty {
                arguments += ", nullstr = '" + nullString.replacingOccurrences(of: "'", with: "''") + "'"
            }
            if let encoding, !encoding.isEmpty {
                arguments += ", encoding = '" + encoding.replacingOccurrences(of: "'", with: "''") + "'"
            }
        }
        return "CREATE TABLE \(quoted(schema)).\(quoted(table)) AS FROM \(reader)(\(arguments))"
    }

    /// The default table name for a file: its stem, lower-cased, every
    /// character that is not a letter, digit or `_` turned into `_`.
    static func tableName(for url: URL) -> String {
        identifier(from: url.deletingPathExtension().lastPathComponent)
    }

    /// A plain SQL identifier from any text (a file stem, a card name).
    static func identifier(from text: String, fallback: String = "imported") -> String {
        var name = String(text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if name.first?.isNumber == true { name = "t_" + name }
        return name.isEmpty ? fallback : name
    }

    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
