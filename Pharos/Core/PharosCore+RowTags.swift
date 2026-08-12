import Foundation
import CPharosCore

// MARK: - Row Tags
//
// Swift side of the row tag FFI declared in pharos-core/include/pharos_core.h
// and implemented in pharos-core/src/ffi/row_tag.rs.
//
// The FFI carries JSON in both directions and uses ONE channel for success and
// failure: a failed call returns the object {"error": "..."} in place of the
// result. The JSON-returning wrappers below therefore reject an error object
// while decoding, and the three scalar-returning ones route through
// `scalarResult`, which detects it and throws — see the comment on that helper.
//
// Payloads encode with JSONEncoder.pharos, which applies NO key strategy. The
// tag models in Pharos/Models/RowTag.swift are already camelCase to match the
// Rust `rename_all = "camelCase"`, so a key strategy here would break the wire
// format. Do not add one.

extension PharosCore {

    // MARK: - Tag Labels

    /// Load the whole label palette, in the core's sort order.
    ///
    /// Labels are global: a label carries no connection id, so this takes no
    /// argument and the same palette applies to every connection.
    static func loadTagLabels() throws -> [TagLabel] {
        try callSync { pharos_load_tag_labels() }
    }

    /// Create a label and return it as stored.
    ///
    /// The core assigns the id, the sort order and the created timestamp, so the
    /// returned label — not the payload — is the record to keep.
    static func createTagLabel(_ label: CreateTagLabel) throws -> TagLabel {
        try callSync(input: label) { pharos_create_tag_label($0) }
    }

    /// Change a label and return it as stored, or nil when no label has that id.
    ///
    /// A nil field in `update` leaves that column as it is. The core returns the
    /// JSON literal `null` for an unknown id, which decodes to nil here; that is
    /// a "not found", not a failure, so it does not throw.
    static func updateTagLabel(_ update: UpdateTagLabel) throws -> TagLabel? {
        try callSync(input: update) { pharos_update_tag_label($0) }
    }

    /// Count the row tags that use one label.
    ///
    /// An unknown label id gives 0, not an error. Use this before a delete to
    /// tell the user how many tags the cascade will take with it.
    static func countTags(forLabel labelId: String) throws -> Int {
        let text = try scalarResult { labelId.withCString { pharos_count_tags_for_label($0) } }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected count result: \(text)")
        }
        return count
    }

    /// Delete a label. Returns true when a row was removed, false when no label
    /// had that id.
    ///
    /// This is a CASCADE delete: the database also removes every row tag that
    /// used the label and every key row of those tags. Call
    /// `countTags(forLabel:)` first if the user must confirm that loss.
    static func deleteTagLabel(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_tag_label($0) } } == "true"
    }

    // MARK: - Row Tags

    /// Load every row tag of one connection.
    ///
    /// Tags are stored per connection, so a tag from another connection never
    /// appears here even when the two databases hold the same table and row.
    static func loadRowTags(connectionId: String) throws -> [RowTag] {
        try jsonResult { connectionId.withCString { pharos_load_row_tags($0) } }
    }

    /// Write a row tag and return it as stored.
    ///
    /// The write is key-set-aware: the core replaces any existing tag that
    /// matches ANY key in `upsert.keys`, not only one that matches the whole
    /// set. That is what holds the one-label-per-row rule when a row is
    /// identified by a different candidate key on a later query — a tag first
    /// stored by primary key is found and replaced when the row comes back
    /// identified by a unique key instead.
    ///
    /// The returned tag carries the stored id and timestamps, so re-tagging an
    /// already-tagged row gives back the surviving record, not the payload.
    static func upsertRowTag(_ upsert: UpsertRowTag) throws -> RowTag {
        try callSync(input: upsert) { pharos_upsert_row_tag($0) }
    }

    /// Delete one row tag. Returns true when a row was removed, false when no
    /// tag had that id. The tag's key rows go with it by database cascade.
    static func deleteRowTag(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_row_tag($0) } } == "true"
    }

    /// Delete many row tags at once and return how many were removed.
    ///
    /// The count can be less than `ids.count`: an id that no longer exists is
    /// skipped, not an error.
    static func deleteRowTags(ids: [String]) throws -> Int {
        let json = String(decoding: try JSONEncoder.pharos.encode(ids), as: UTF8.self)
        let text = try scalarResult { json.withCString { pharos_delete_row_tags($0) } }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected delete count result: \(text)")
        }
        return count
    }

    // MARK: - Private FFI Helpers

    /// The core's message when `text` is the failure object {"error": "..."},
    /// otherwise nil.
    ///
    /// Both helpers below share this one check so that the error channel is read
    /// the same way for a scalar return and a JSON return.
    private static func rustErrorMessage(in text: String) -> String? {
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }

    /// Read a C-string return that is a SCALAR, not JSON, and throw when the core
    /// returned an error object instead.
    ///
    /// The FFI uses one channel for both: success gives `true`, `false` or a
    /// decimal, and failure gives `{"error": "..."}`. Testing the success text
    /// alone (`== "true"`) silently turns a failure into a negative answer, which
    /// is how the existing wrappers behave and why this helper exists. Every
    /// scalar wrapper above goes through here so that the check cannot be
    /// forgotten at one call site.
    private static func scalarResult(
        _ ffi: () -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        guard let ptr = ffi() else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let text = String(cString: ptr)
        if let message = rustErrorMessage(in: text) {
            throw PharosCoreError.rustError(message)
        }
        return text
    }

    /// Call an FFI function that takes a plain C-string and returns JSON, and
    /// decode the result.
    ///
    /// `callSync` covers "nothing in" and "JSON in"; this covers the third
    /// shape. The error object is checked before the decode so that a real
    /// failure reports the core's own message instead of a decoding complaint.
    private static func jsonResult<T: Decodable>(
        _ ffi: () -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard let ptr = ffi() else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        if let message = rustErrorMessage(in: json) {
            throw PharosCoreError.rustError(message)
        }
        do {
            return try JSONDecoder.pharos.decode(T.self, from: Data(json.utf8))
        } catch {
            throw PharosCoreError.decodingError(json, error)
        }
    }
}
