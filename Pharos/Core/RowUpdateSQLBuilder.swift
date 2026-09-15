import Foundation

/// Renders the pending cell edits two ways: as a `RowUpdateRequest` for the
/// core, and as the UPDATE statements the review sheet shows.
///
/// ═══════════════════════════════════════════════════════════════════════════
///  THE TEXT THIS FILE BUILDS IS NEVER EXECUTED. NOT BY THIS APP, NOT BY THE
///  CORE, NOT BY ANYTHING.
///
///  `pharos_apply_row_updates` receives the `RowUpdateRequest` — a table, a
///  key, and per row the key values, the old values and the new values, all as
///  plain text. It builds its own statement there with every value BOUND as a
///  parameter and every identifier escaped. The strings below exist so a person
///  can read what is about to happen before they approve it, which is the
///  entire point of the review sheet.
///
///  So do not be tempted to "save a round trip" by sending this text anywhere.
///  It renders values inline for READING: a value that is quoted here is quoted
///  for a human's eye, not for a parser's, and treating it as executable SQL
///  would turn a cell's contents into the one injection hole this design does
///  not otherwise have.
/// ═══════════════════════════════════════════════════════════════════════════
enum RowUpdateSQLBuilder {

    // MARK: - Request construction

    /// Build the request for every pending edit, or nil when the pending set
    /// cannot be turned into one safely.
    ///
    /// nil means "do not offer to apply": no edits, no identity, more than one
    /// source table, a table name the core did not resolve, a key column that
    /// is not in the result, or a row whose key value is NULL. Each of those is
    /// already refused at the point of EDITING by `CellEditability`, so a nil
    /// here means the result changed underneath the pending set — in which case
    /// refusing is right.
    static func makeRequest(
        pending: PendingCellEdits,
        columns: [ColumnDef],
        rows: [[AnyCodable]],
        rowIdentity: RowIdentity?
    ) -> RowUpdateRequest? {
        guard !pending.isEmpty,
              let identity = rowIdentity,
              let candidate = CellEditability.strongestCandidate(of: identity),
              identity.tableKeys.count == 1,
              let tableOid = CellEditability.tableOid(of: identity),
              let (schema, table) = splitQualifiedName(identity.tableDisplay)
        else { return nil }

        // The edited columns, in result order. Every row of the request writes
        // this same list, so the statements line up column for column and the
        // reader can compare two rows at a glance.
        let editedIndices = pending.columnIndices
        guard editedIndices.allSatisfy({ $0 >= 0 && $0 < columns.count }) else { return nil }
        let requestColumns = editedIndices.map {
            RowUpdateRequest.Column(name: columns[$0].name, dataType: columns[$0].dataType)
        }

        // Where each key column sits in the result. Matched on NAME plus the
        // identity's own table OID, because a join can put a column of the
        // same name in the result twice and only one of them is this table's.
        // `first` mirrors the core's `position_of` map, which keeps the FIRST
        // position for a column selected twice — the two must agree or the key
        // read here is not the key the core built.
        var keyIndices: [Int] = []
        for name in candidate.keyColumns {
            guard let idx = columns.firstIndex(where: {
                $0.name == name && $0.relationOid == tableOid && $0.relationAttno != nil
            }) else { return nil }
            keyIndices.append(idx)
        }
        guard !keyIndices.isEmpty else { return nil }
        let keyColumns = keyIndices.map {
            RowUpdateRequest.Column(name: columns[$0].name, dataType: columns[$0].dataType)
        }

        var requestRows: [RowUpdateRequest.Row] = []
        for dataRow in pending.rows {
            guard dataRow >= 0, dataRow < rows.count else { return nil }
            let row = rows[dataRow]

            // A NULL key value would make the WHERE clause match nothing (or,
            // worse, everything with a NULL there). The core already refuses
            // such a row by writing "" for its key, and so does
            // `CellEditability`; this is the third and last gate.
            var key: [String] = []
            for idx in keyIndices {
                guard idx < row.count, let text = row[idx].stringValue else { return nil }
                key.append(text)
            }

            var oldValues: [String?] = []
            var newValues: [String?] = []
            for idx in editedIndices {
                let loaded = idx < row.count ? row[idx].stringValue : nil
                oldValues.append(loaded)
                // A column this row did not edit is written back with the value
                // it already has. It costs one bound parameter and keeps every
                // row of the request the same shape, which is what lets the
                // core send one prepared statement per row instead of N shapes.
                //
                // Written as an `if let` on the EDIT, not as
                // `edit?.newText ?? loaded`: `newText` is itself optional, so
                // optional chaining flattens "there is an edit and its new
                // value is NULL" into the same nil as "there is no edit", and
                // the `??` then puts the old value back. That is a Set NULL
                // silently doing nothing — the one class of bug this whole
                // design exists to avoid.
                if let edit = pending.edit(at: dataRow, columnIndex: idx) {
                    newValues.append(edit.newText)
                } else {
                    newValues.append(loaded)
                }
            }

            requestRows.append(RowUpdateRequest.Row(key: key, oldValues: oldValues, newValues: newValues))
        }

        return RowUpdateRequest(
            schema: schema,
            table: table,
            keyColumns: keyColumns,
            keyDescription: keyDescription(kind: candidate.kind, columns: candidate.keyColumns),
            columns: requestColumns,
            rows: requestRows
        )
    }

    /// `"public.users"` → `("public", "users")`.
    ///
    /// Split at the FIRST dot: the core builds this string as
    /// `nspname || '.' || relname`, and a dot is far likelier inside a table
    /// name than inside a schema name. A string with no dot at all (the
    /// `unknown table (oid N)` fallback) yields nil, which refuses the apply.
    static func splitQualifiedName(_ display: String) -> (schema: String, table: String)? {
        guard let dot = display.firstIndex(of: ".") else { return nil }
        let schema = String(display[display.startIndex..<dot])
        let table = String(display[display.index(after: dot)...])
        guard !schema.isEmpty, !table.isEmpty else { return nil }
        return (schema, table)
    }

    // MARK: - Naming the key

    /// `primary key (id)` / `unique index (email)` / `primary key (a, b)`.
    static func keyDescription(kind: String, columns: [String]) -> String {
        let noun = kind == "pk"
            ? String(localized: "primary key")
            : String(localized: "unique index")
        return "\(noun) (\(columns.joined(separator: ", ")))"
    }

    /// The sheet's footnote. The user has to be told WHICH key their rows are
    /// matched on, because a unique index standing in for a missing primary
    /// key is a different promise from a primary key.
    static func footnote(for request: RowUpdateRequest) -> String {
        String(localized: "Rows are matched on the \(request.keyDescription).")
    }

    // MARK: - Statement text (for reading only — see the file comment)

    /// One `UPDATE` per row, in row order.
    static func statements(for request: RowUpdateRequest) -> [String] {
        let target = quotedQualifiedName(schema: request.schema, table: request.table)
        return request.rows.map { row in
            let sets = zip(request.columns, row.newValues).map { column, value in
                "\(quotedSqlIdentifier(column.name)) = \(literal(value, dataType: column.dataType))"
            }
            var wheres = zip(request.keyColumns, row.key).map { column, value in
                "\(quotedSqlIdentifier(column.name)) = \(literal(value, dataType: column.dataType))"
            }
            // The old-value guard. `IS NOT DISTINCT FROM` and not `=`, so a
            // NULL old value matches a NULL still in the table: with `=` a
            // NULL would compare to unknown, the row would not match, and a
            // perfectly ordinary edit of a NULL cell would roll the whole
            // transaction back.
            wheres += zip(request.columns, row.oldValues).map { column, value in
                "\(quotedSqlIdentifier(column.name)) IS NOT DISTINCT FROM \(literal(value, dataType: column.dataType))"
            }
            return "UPDATE \(target) SET \(sets.joined(separator: ", ")) WHERE \(wheres.joined(separator: " AND "));"
        }
    }

    /// The whole block, one statement per line, for the sheet's text view.
    static func text(for request: RowUpdateRequest) -> String {
        statements(for: request).joined(separator: "\n")
    }

    /// The number of CELLS the request changes — what the title and the bar
    /// count. Derived from the request rather than passed in, so the number on
    /// screen can never disagree with the statements under it.
    static func changeCount(for request: RowUpdateRequest) -> Int {
        request.rows.reduce(0) { total, row in
            total + zip(row.oldValues, row.newValues).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        }
    }

    /// `Apply 3 changes to public.users?`
    static func title(for request: RowUpdateRequest) -> String {
        let changes = CountedNounText.phrase(changeCount(for: request), "change")
        return String(localized: "Apply \(changes) to \(request.schema).\(request.table)?")
    }

    /// One value, rendered for a person to READ. Never for execution — the
    /// core binds the value this stands for.
    ///
    /// NULL prints bare; a number and a boolean print bare so the statement
    /// reads the way the user would write it; everything else is single-quoted
    /// with embedded `'` doubled.
    static func literal(_ value: String?, dataType: String) -> String {
        guard let value else { return "NULL" }
        switch CellEditability.family(of: dataType) {
        case .numeric where looksNumeric(value):
            return value
        case .boolean:
            switch value.lowercased() {
            case "t", "true": return "true"
            case "f", "false": return "false"
            default: return quotedLiteral(value)
            }
        default:
            // Includes a numeric column holding something that is not a number
            // — a value the user typed that the server will reject. Quoting it
            // keeps the preview readable as a VALUE rather than letting it
            // masquerade as an identifier or an operator.
            return quotedLiteral(value)
        }
    }

    /// `.literal` for the same reason `quotedSqlIdentifier` uses it: matching
    /// by code unit, so a `'` fused to a combining mark is still doubled.
    private static func quotedLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''", options: .literal) + "'"
    }

    /// Whether the text is an unadorned SQL numeric literal. Deliberately
    /// strict: an optional sign, digits, at most one dot, at least one digit.
    /// No exponent, no leading `+.`, no whitespace — anything else is quoted.
    private static func looksNumeric(_ value: String) -> Bool {
        var seenDot = false
        var seenDigit = false
        for (i, character) in value.enumerated() {
            if character == "-" || character == "+" {
                guard i == 0 else { return false }
            } else if character == "." {
                guard !seenDot else { return false }
                seenDot = true
            } else if character.isASCII && character.isNumber {
                seenDigit = true
            } else {
                return false
            }
        }
        return seenDigit
    }
}
