import Foundation
import CPharosCore

// MARK: - Workspaces
//
// The workspace FFI answers a bare "true"/"false" — or the new id, for a
// duplicate — on success, and the object {"error": ...} on failure. That is the
// single-channel convention, not the NULL-on-success one of `callSyncVoid`, so
// these wrappers go through `scalarResult` in PharosCore.swift. This file used to
// carry its own private copy of that check.

extension PharosCore {

    /// Create or refresh a workspace snapshot.
    static func upsertWorkspace(_ w: WorkspaceUpsert) throws {
        _ = try scalarResult(input: w) { pharos_upsert_workspace($0) }
    }

    struct ResultAssociation: Codable {
        let historyId: String
        let workspaceId: String
        let resultOrder: Int
        let colorIndex: Int
        let rawSql: String?
    }

    /// Associate a produced result (by its history id) with a workspace.
    static func associateResult(_ a: ResultAssociation) throws {
        _ = try scalarResult(input: a) { pharos_associate_result($0) }
    }

    struct WorkspaceFilter: Codable {
        var search: String? = nil
        var limit: Int? = 200
        var offset: Int? = 0
    }

    /// Load workspace summaries for the sidebar list.
    static func loadWorkspaces(filter: WorkspaceFilter = WorkspaceFilter()) throws -> [WorkspaceSummary] {
        try callSync(input: filter) { pharos_load_workspaces($0) }
    }

    /// Load a full workspace (editor text, variables, ordered result metadata).
    /// Returns nil if the workspace no longer exists.
    ///
    /// This cannot use `jsonResult`, which throws on a NULL return. Here NULL is
    /// the "no such workspace" answer and must give nil.
    static func loadWorkspace(id: String) throws -> WorkspaceDetail? {
        guard let json = try checkedText({ id.withCString { pharos_load_workspace($0) } })
        else { return nil }
        do {
            return try JSONDecoder.pharos.decode(WorkspaceDetail.self, from: Data(json.utf8))
        } catch {
            throw PharosCoreError.decodingError(json, error)
        }
    }

    struct RenamePayload: Codable { let id: String; let name: String }

    @discardableResult
    static func renameWorkspace(id: String, name: String) throws -> Bool {
        try scalarResult(input: RenamePayload(id: id, name: name)) { pharos_rename_workspace($0) } == "true"
    }

    /// Duplicate a workspace (deep copy). Returns the new workspace id, or nil if not found.
    ///
    /// The success return is the new id — a scalar, not JSON — and NULL is the
    /// "not found" answer, which is exactly what `checkedText` gives.
    static func duplicateWorkspace(id: String) throws -> String? {
        try checkedText { id.withCString { pharos_duplicate_workspace($0) } }
    }

    @discardableResult
    static func deleteWorkspace(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_workspace($0) } } == "true"
    }

    @discardableResult
    static func deleteWorkspaceResult(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_workspace_result($0) } } == "true"
    }

    struct UpdateResultMetaPayload: Codable { let resultId: String; let customLabel: String?; let colorIndex: Int? }

    /// Change a saved result's display metadata.
    ///
    /// `resultId` is the `query_history` row id — `ResultTab.historyResultId`,
    /// or `WorkspaceResultMeta.id`.
    ///
    /// Each field is optional and nil means "leave it alone", so a caller
    /// changing one need not know the other. To CLEAR a custom name, pass the
    /// empty string: `nil` would leave the stored name in place. That is the
    /// core's convention, not this wrapper's — see `update_result_meta` in
    /// `pharos-core/src/db/sqlite.rs`.
    @discardableResult
    static func updateResultMeta(resultId: String, customLabel: String? = nil, colorIndex: Int? = nil) throws -> Bool {
        let payload = UpdateResultMetaPayload(resultId: resultId, customLabel: customLabel, colorIndex: colorIndex)
        return try scalarResult(input: payload) { pharos_update_result_meta($0) } == "true"
    }

    struct UpdateResultChartStatePayload: Codable { let resultId: String; let json: String }

    @discardableResult
    static func updateResultChartState(resultId: String, json: String) throws -> Bool {
        let payload = UpdateResultChartStatePayload(resultId: resultId, json: json)
        return try scalarResult(input: payload) { pharos_update_result_chart_state($0) } == "true"
    }
}
