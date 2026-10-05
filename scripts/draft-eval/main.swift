// Grades a "Describe a query" drafter against the fixture database.
//
// Each case is one analyst request plus what a correct answer must contain:
// the tables it has to read (each inner list is "any one of these") and a few
// regular expressions over the SQL. A case passes when the draft
//   1. prepares AND executes inside BEGIN READ ONLY … ROLLBACK on the fixture
//      database (the GRADER runs SQL; the app never does),
//   2. names every required table, and
//   3. matches every pattern.
//
// The drafter itself is supplied by an adapter file compiled alongside this
// one: `evalDraft(_:catalog:)`. The baseline adapter wraps the tool-calling
// drafter on main; the pipeline adapter wraps the multi-step one.
//
// Environment:
//   EVAL_DB       database name (default pharos_draft_eval)
//   EVAL_CATALOG  catalogue JSON written by eval-sql-draft.sh
//   EVAL_CASES    cases JSON
//   EVAL_OUT      where to write the per-case results JSON
//   EVAL_ONLY     comma-separated case ids to run (default: all)
//   EVAL_TIMEOUT  seconds per case (default 90)
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

struct EvalCase: Decodable {
    let id: String
    let schema: String
    let request: String
    let tables: [[String]]
    let match: [String]
}

struct EvalOutput {
    var sql: String
    var note: String
    /// Free text the adapter wants in the report: steps taken, tokens, picks.
    var detail: String = ""
}

struct EvalResult: Encodable {
    let id: String
    let request: String
    let sql: String
    let note: String
    let detail: String
    let error: String?
    let seconds: Double
    let executed: Bool
    let executeError: String?
    let missingTables: [String]
    let missingMatches: [String]
    let pass: Bool
}

struct TimedOut: Error, CustomStringConvertible {
    var description: String { "timedOut" }
}

let env = ProcessInfo.processInfo.environment
let database = env["EVAL_DB"] ?? "pharos_draft_eval"
let psql = "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"
let timeout = Double(env["EVAL_TIMEOUT"] ?? "") ?? 90

func load<T: Decodable>(_ type: T.Type, from key: String) -> T {
    guard let path = env[key] else { fatalError("\(key) is not set") }
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return try! JSONDecoder().decode(T.self, from: data)
}

/// Runs the draft on the fixture database, read-only, and rolls back.
func execute(_ sql: String, schema: String) -> String? {
    var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    while body.hasSuffix(";") { body.removeLast() }
    let script = """
        BEGIN READ ONLY;
        SET LOCAL search_path = \(schema), public;
        PREPARE p AS \(body);
        EXECUTE p;
        ROLLBACK;
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: psql)
    process.arguments = ["-h", "127.0.0.1", "-d", database, "-v", "ON_ERROR_STOP=1", "-Atq", "-f", "-"]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try! process.run()
    input.fileHandleForWriting.write(script.data(using: .utf8)!)
    try? input.fileHandleForWriting.close()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    if process.terminationStatus == 0 { return nil }
    return message.split(separator: "\n").first { $0.contains("ERROR") }.map(String.init) ?? message
}

/// Lower-cased with double quotes removed, so `sales."ReturnRequests"` reads
/// as `sales.returnrequests`.
func normalised(_ sql: String) -> String {
    sql.lowercased().replacingOccurrences(of: "\"", with: "")
}

func names(_ table: String, in sql: String) -> Bool {
    sql.range(of: "\\b\(NSRegularExpression.escapedPattern(for: table))\\b", options: .regularExpression) != nil
}

@MainActor
func run(_ c: EvalCase, catalog: EvalCatalog) async -> EvalResult {
    let start = Date()
    var output: EvalOutput?
    var failure: String?
    do {
        output = try await withThrowingTaskGroup(of: EvalOutput.self) { group in
            group.addTask { try await evalDraft(c, catalog: catalog) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TimedOut()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    } catch {
        failure = String(describing: error)
    }
    let seconds = Date().timeIntervalSince(start)

    let sql = output?.sql ?? ""
    let flat = normalised(sql)
    let executeError = sql.isEmpty ? "no SQL" : execute(sql, schema: c.schema)
    let missingTables = c.tables
        .filter { group in !group.contains { names($0, in: flat) } }
        .map { $0.joined(separator: "|") }
    let missingMatches = c.match.filter {
        flat.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil
    }
    let pass = failure == nil && executeError == nil && missingTables.isEmpty && missingMatches.isEmpty
    return EvalResult(
        id: c.id, request: c.request, sql: sql, note: output?.note ?? "",
        detail: output?.detail ?? "", error: failure, seconds: seconds,
        executed: executeError == nil, executeError: executeError,
        missingTables: missingTables, missingMatches: missingMatches, pass: pass)
}

let catalog = load(EvalCatalog.self, from: "EVAL_CATALOG")
var cases = load([EvalCase].self, from: "EVAL_CASES")
if let only = env["EVAL_ONLY"], !only.isEmpty {
    let wanted = Set(only.split(separator: ",").map(String.init))
    cases = cases.filter { wanted.contains($0.id) }
}

var results: [EvalResult] = []
for c in cases {
    let result = await run(c, catalog: catalog)
    results.append(result)
    let verdict = result.pass ? "PASS" : "FAIL"
    print("\(verdict) \(c.id) (\(String(format: "%.1f", result.seconds)) s)")
    if !result.pass {
        if let error = result.error { print("    error: \(error)") }
        if let executeError = result.executeError { print("    execute: \(executeError)") }
        if !result.missingTables.isEmpty { print("    missing tables: \(result.missingTables)") }
        if !result.missingMatches.isEmpty { print("    missing patterns: \(result.missingMatches)") }
    }
    if !result.sql.isEmpty {
        print("    sql: " + result.sql.replacingOccurrences(of: "\n", with: " "))
    }
    if !result.detail.isEmpty { print("    detail: \(result.detail)") }
}

let passed = results.filter(\.pass).count
let executed = results.filter(\.executed).count
let errors = results.filter { $0.error != nil }.count
let times = results.map(\.seconds).sorted()
let median = times.isEmpty ? 0 : times[times.count / 2]
print("")
print("passed \(passed)/\(results.count); executed \(executed)/\(results.count); model errors \(errors)")
print(String(format: "median %.1f s, worst %.1f s", median, times.last ?? 0))

if let out = env["EVAL_OUT"] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! encoder.encode(results).write(to: URL(fileURLWithPath: out))
}
