// Just enough of the app for SQLDraft.swift to compile alone.
// `IntelligenceInstructions` is copied from IntelligenceSession.swift, which
// would otherwise pull in ModelAvailability and the settings graph;
// eval-sql-draft.sh fails the run if the two copies of `sqlSafety` drift
// apart. Also compiled by scripts/test-sql-draft-backend.sh.
import Foundation
import os

enum Log {
    static let intelligence = Logger(subsystem: "draft-eval", category: "intelligence")
}

enum IntelligenceInstructions {
    static func inDialect(_ text: String, _ dialect: String) -> String {
        dialect == "PostgreSQL" ? text : text.replacingOccurrences(of: "PostgreSQL", with: dialect)
    }

    static let sqlSafety = """
        You help a PostgreSQL analyst. Never propose DROP, DELETE, TRUNCATE, \
        ALTER or UPDATE statements. Do not run anything; you only write text.
        """
}
