import Foundation

/// Quotes a SQL identifier for PostgreSQL: wraps it in double quotes and
/// doubles any embedded `"` characters, so a hostile name like
/// `a"; DROP TABLE x; --` stays one identifier instead of breaking out of
/// the quoting and injecting SQL.
///
/// Lives in its own file (not on any view controller or generator) because
/// several call sites across the app quote identifiers, and standalone test
/// harnesses (see `scripts/test-sql-identifier-quoting.sh`) must link the
/// REAL production function — pure Foundation, no AppKit.
func quotedSqlIdentifier(_ name: String) -> String {
    // `.literal` matches by code unit, not by grapheme cluster. Without it a
    // `"` fused to a following combining mark (e.g. U+0022 U+0301) is one
    // grapheme and is NOT doubled, so the hostile quote survives and the
    // identifier still breaks out. `.literal` doubles every raw `"`.
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
}

/// Quotes a schema-qualified table/view name: `"schema"."table"` with both
/// parts individually quoted via `quotedSqlIdentifier`.
func quotedQualifiedName(schema: String, table: String) -> String {
    quotedSqlIdentifier(schema) + "." + quotedSqlIdentifier(table)
}
