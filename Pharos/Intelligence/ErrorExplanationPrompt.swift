import Foundation

/// The prompt behind "Explain this error", and nothing else.
///
/// Pure on purpose. Everything that decides WHAT the model is shown lives here,
/// with no AppKit, no `MetadataCache` and no `FoundationModels`, so the rules
/// below can be tested on their own — see `PharosTests/ErrorExplanationPromptTests.swift`.
///
/// Two rules the type exists to enforce:
///
///  - **No row values.** `KnownObjects` can carry a name and a type and nothing
///    else, so there is no field a cell value could arrive in. The statement is
///    the user's own text and goes in as written; the model is never handed a
///    result set.
///  - **Only what the statement names.** A database can hold thousands of
///    columns. Sending them all would waste the context window and put schema
///    the query never mentioned in front of the model, so a table is described
///    only when the statement names it, and only the columns the statement
///    names are listed with it.
struct ErrorExplanationPrompt {

    // MARK: - What the model may be told about the schema

    /// One column, as a name and a type. There is deliberately no third field:
    /// a value has nowhere to go.
    struct Column: Equatable {
        let name: String
        let type: String

        init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// One table the prompt may describe.
    struct TableRef: Equatable {
        let schema: String
        let table: String
        let columns: [Column]

        init(schema: String, table: String, columns: [Column]) {
            self.schema = schema
            self.table = table
            self.columns = columns
        }
    }

    /// The schema the caller is willing to describe, before filtering. Built by
    /// hand in a test and from `MetadataCache` in the app — see
    /// `ErrorExplanationPrompt+Cache.swift`.
    struct KnownObjects: Equatable {
        let tables: [TableRef]

        init(tables: [TableRef]) {
            self.tables = tables
        }

        /// Nothing known. A disconnected tab, or a statement that names no
        /// cached table.
        static let none = KnownObjects(tables: [])
    }

    // MARK: - Limits

    /// The most statement text that goes in a prompt.
    ///
    /// A generated migration or a pasted dump can run to megabytes, which would
    /// exceed the context window and fail the whole generation. The head of the
    /// statement is the part the error position points into, so the tail is what
    /// gives way.
    static let sqlCharacterLimit = 4000

    /// Marks the cut, so the model does not read a truncated statement as a
    /// syntax error of its own.
    static let truncationMarker = "-- (statement truncated)"

    // MARK: - Building

    /// The whole prompt for one failure.
    ///
    /// `message` goes in verbatim: PostgreSQL's wording, its `at character N`
    /// suffix and its hints are the most useful thing in the prompt, and any
    /// tidying here would be tidying away the evidence.
    static func build(message: String, sql: String, knownObjects: KnownObjects) -> String {
        var prompt = """
            A PostgreSQL statement failed. Explain the error to the analyst who ran it.

            error message: \(message)

            statement:
            \(cap(sql))
            """

        let described = describe(knownObjects: knownObjects, mentionedIn: sql)
        if !described.isEmpty {
            prompt += "\n\nknown objects: \(described)"
        }
        return prompt
    }

    /// `sql`, cut to `sqlCharacterLimit` characters with the cut marked.
    static func cap(_ sql: String) -> String {
        guard sql.count > sqlCharacterLimit else { return sql }
        return String(sql.prefix(sqlCharacterLimit)) + "\n" + truncationMarker
    }

    /// "public.users(id integer, email text), public.orders" — the tables `sql`
    /// names, each with the columns `sql` names.
    ///
    /// A table the statement does not name is left out even when one of its
    /// columns is named: a column called `id` or `name` appears in most tables
    /// in most databases, and matching on it would drag the whole catalogue in.
    /// Columns listed per named table before "…" takes over.
    static let columnCap = 60

    static func describe(knownObjects: KnownObjects, mentionedIn sql: String) -> String {
        let names = identifiers(in: sql)
        guard !names.isEmpty else { return "" }

        // A table the statement names is described with ALL its columns
        // (names and types, capped), not only the ones the statement uses:
        // "column nme does not exist" is only fixable when the model can see
        // that `name` exists. Tables the statement does not name stay out, so
        // the prompt stays inside the on-device context window.
        let described = knownObjects.tables.compactMap { table -> String? in
            guard names.contains(fold(table.table)) else { return nil }
            let columns = table.columns
                .prefix(Self.columnCap)
                .map { "\($0.name) \($0.type)" }
            guard !columns.isEmpty else { return "\(table.schema).\(table.table)" }
            let more = table.columns.count > Self.columnCap ? ", …" : ""
            return "\(table.schema).\(table.table)(\(columns.joined(separator: ", "))\(more))"
        }
        return described.joined(separator: ", ")
    }

    // MARK: - Identifier scan

    /// Every identifier-shaped token in `sql`, folded for comparison.
    ///
    /// Three things it is careful about:
    ///
    ///  - A `"quoted identifier"` is one token, including its spaces, because
    ///    that is how PostgreSQL reads it.
    ///  - A `'string literal'` is skipped entirely. It holds a VALUE, and a row
    ///    that happens to read `'users'` must not pull the `users` table into
    ///    the prompt.
    ///  - `schema.table` splits at the dot into two tokens, so either half can
    ///    match on its own.
    static func identifiers(in sql: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        let scalars = Array(sql.unicodeScalars)
        var i = 0

        func flush() {
            if !current.isEmpty {
                tokens.insert(fold(current))
                current = ""
            }
        }

        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "'" {
                // A literal, including its doubled-quote escapes. Nothing in it
                // is an identifier.
                flush()
                i += 1
                while i < scalars.count {
                    if scalars[i] == "'" {
                        if i + 1 < scalars.count, scalars[i + 1] == "'" { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i += 1
                continue
            }
            if scalar == "\"" {
                flush()
                i += 1
                var quoted = ""
                while i < scalars.count {
                    if scalars[i] == "\"" {
                        if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                            quoted.unicodeScalars.append("\"")
                            i += 2
                            continue
                        }
                        break
                    }
                    quoted.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1
                if !quoted.isEmpty { tokens.insert(fold(quoted)) }
                continue
            }
            if isIdentifierScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
            i += 1
        }
        flush()
        return tokens
    }

    /// The comparison form. PostgreSQL folds an unquoted identifier to lower
    /// case, so matching case-insensitively is the behaviour the server has —
    /// and a quoted `"Users"` still finds the cached `users` this way, which is
    /// the answer the user wants even where the server would disagree.
    private static func fold(_ name: String) -> String { name.lowercased() }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
}
