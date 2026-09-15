import Foundation
import CPharosCore

extension PharosCore {
    /// Applies pending cell edits in ONE transaction: one UPDATE per row with
    /// every value bound, `RETURNING 1`, and a rollback unless every row
    /// matched exactly one. The error string is the core's message.
    static func applyRowUpdates(connectionId: String, request: RowUpdateRequest) async throws -> RowUpdateResult {
        let json = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                json.withCString { cJson in
                    pharos_apply_row_updates(cConn, cJson, callback, context)
                }
            }
        }
    }
}
