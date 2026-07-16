import Foundation
import CPharosCore

// MARK: - Workspaces

extension PharosCore {

    /// Create or refresh a workspace snapshot.
    static func upsertWorkspace(_ w: WorkspaceUpsert) throws {
        _ = try callBoolResult(input: w) { pharos_upsert_workspace($0) }
    }

    struct ResultAssociation: Codable {
        let historyId: String
        let workspaceId: String
        let resultOrder: Int
        let colorIndex: Int
    }

    /// Associate a produced result (by its history id) with a workspace.
    static func associateResult(_ a: ResultAssociation) throws {
        _ = try callBoolResult(input: a) { pharos_associate_result($0) }
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
    static func loadWorkspace(id: String) throws -> WorkspaceDetail? {
        guard let ptr = id.withCString({ pharos_load_workspace($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        try throwIfError(json)
        return try JSONDecoder.pharos.decode(WorkspaceDetail.self, from: Data(json.utf8))
    }

    struct RenamePayload: Codable { let id: String; let name: String }

    @discardableResult
    static func renameWorkspace(id: String, name: String) throws -> Bool {
        try callBoolResult(input: RenamePayload(id: id, name: name)) { pharos_rename_workspace($0) }
    }

    /// Duplicate a workspace (deep copy). Returns the new workspace id, or nil if not found.
    static func duplicateWorkspace(id: String) throws -> String? {
        guard let ptr = id.withCString({ pharos_duplicate_workspace($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s
    }

    @discardableResult
    static func deleteWorkspace(id: String) throws -> Bool {
        try callBoolString(arg: id) { pharos_delete_workspace($0) }
    }

    @discardableResult
    static func deleteWorkspaceResult(id: String) throws -> Bool {
        try callBoolString(arg: id) { pharos_delete_workspace_result($0) }
    }

    struct UpdateResultMetaPayload: Codable { let resultId: String; let customLabel: String?; let colorIndex: Int? }

    @discardableResult
    static func updateResultMeta(resultId: String, customLabel: String? = nil, colorIndex: Int? = nil) throws -> Bool {
        try callBoolResult(input: UpdateResultMetaPayload(resultId: resultId, customLabel: customLabel, colorIndex: colorIndex)) {
            pharos_update_result_meta($0)
        }
    }
}

// MARK: - Bool/error FFI helpers
//
// The workspace FFI returns a bare "true"/"false" on success or a `{"error": ...}`
// JSON object on failure — so the shared `callSyncVoid` (which treats any non-NULL
// return as an error) does not fit. These mirror the manual error-dict handling
// used in PharosCore+QueryHistory.swift.

private extension PharosCore {
    /// Throw if `json` is a Rust `{"error": "..."}` payload; otherwise return.
    static func throwIfError(_ json: String) throws {
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = dict["error"] as? String {
            throw PharosCoreError.rustError(msg)
        }
    }

    /// JSON-in; expects a bare "true"/"false" or error JSON out.
    static func callBoolResult<T: Encodable>(input: T, _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) throws -> Bool {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(input), as: UTF8.self)
        guard let ptr = jsonStr.withCString({ call($0) }) else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s == "true"
    }

    /// String-arg in; expects a bare "true"/"false" or error JSON out.
    static func callBoolString(arg: String, _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) throws -> Bool {
        guard let ptr = arg.withCString({ call($0) }) else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s == "true"
    }
}
