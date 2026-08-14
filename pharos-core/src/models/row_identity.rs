/// One key index of a table, from the catalogue. Cached per connection.
#[derive(Debug, Clone, PartialEq)]
pub struct KeyCandidate {
    /// The key column `attnum`s, in index order. INCLUDE columns are excluded.
    /// Named for its contents: `KeySet.key_columns` is the one that holds column
    /// NAMES, and the two appear together in `assemble_row_identity`, which
    /// turns each candidate's attnums into that set's names.
    pub column_attnums: Vec<i16>,
    pub is_primary: bool,
    pub all_not_null: bool,
}

/// A cached catalogue entry for one table.
#[derive(Debug, Clone)]
pub struct TableKeyInfo {
    /// "public.users"
    pub display: String,
    pub candidates: Vec<KeyCandidate>,
}
