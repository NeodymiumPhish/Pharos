import Foundation
import CPharosCore

// MARK: - Session (open tabs across launches)

extension PharosCore {

    /// Load the tab set stored at the end of the last run. An empty `tabs`
    /// array is a normal answer, not a failure.
    static func loadSession() throws -> Session {
        try callSync { pharos_load_session() }
    }

    /// Replace the stored tab set.
    static func saveSession(_ session: Session) throws {
        try callSyncVoid(input: session) { pharos_save_session($0) }
    }
}
