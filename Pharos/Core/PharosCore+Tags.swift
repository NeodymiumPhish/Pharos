import Foundation
import CPharosCore

// MARK: - Unified Tags
//
// Swift side of the tag FFI declared in pharos-core/include/pharos_core.h and
// implemented in pharos-core/src/ffi/tag.rs.
//
// The FFI carries JSON in both directions and uses ONE channel for success and
// failure: a failed call returns {"error": "..."} in place of the result. Every
// wrapper below therefore goes through `callSync`, `jsonResult` or
// `scalarResult` in PharosCore.swift, which detect that object and throw.
//
// Payloads encode with JSONEncoder.pharos, which applies NO key strategy. The
// models in Pharos/Models/Tag.swift are already camelCase to match the Rust
// `rename_all = "camelCase"`. Do not add a key strategy here.

extension PharosCore {

    /// Every tag with its tuples.
    ///
    /// Tags are GLOBAL: no connection argument, because a tag matches in every
    /// dataset. That is the whole point of the model — the cross-connection
    /// overlap is the analytic payoff.
    static func loadTags() throws -> [Tag] {
        try callSync { pharos_load_tags() }
    }

    /// Create a tag with its first tuples, and return it as stored.
    ///
    /// The core assigns the tag id, every tuple id and both timestamps, so the
    /// RETURNED tag — not the payload — is the record to keep.
    static func createTag(_ create: CreateTag) throws -> Tag {
        try callSync(input: create) { pharos_create_tag($0) }
    }

    /// Append tuples to an existing tag. Returns how many were actually
    /// inserted: a tuple already on the tag is absorbed by the unique index,
    /// not an error, so re-tagging the same row is a no-op.
    @discardableResult
    static func addTagTuples(_ payload: AddTagTuples) throws -> Int {
        let text = try scalarResult(input: payload) { pharos_add_tag_tuples($0) }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected add count result: \(text)")
        }
        return count
    }

    /// Change a tag's name, colour or note. Returns nil when no tag has that id.
    static func updateTag(_ update: UpdateTag) throws -> Tag? {
        try callSync(input: update) { pharos_update_tag($0) }
    }

    /// Delete a tag. Its tuples go with it by database cascade.
    static func deleteTag(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_tag($0) } } == "true"
    }

    /// Remove individual tuples — the "Remove From Tag" path. A tag that loses
    /// every tuple survives; it is still a named case.
    @discardableResult
    static func deleteTagTuples(ids: [String]) throws -> Int {
        let text = try scalarResult(input: ids) { pharos_delete_tag_tuples($0) }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected delete count result: \(text)")
        }
        return count
    }
}
