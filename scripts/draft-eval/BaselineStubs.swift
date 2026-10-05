// Just enough of the app for the baseline SQLDraft.swift to compile alone.
// `IntelligenceInstructions.sqlSafety` is copied from main's
// IntelligenceSession.swift, which would otherwise pull in ModelAvailability
// and the whole settings graph.
import Foundation
import os

enum Log {
    static let intelligence = Logger(subsystem: "draft-eval", category: "intelligence")
}

enum IntelligenceInstructions {
    static let sqlSafety = """
        You help a PostgreSQL analyst. Never propose DROP, DELETE, TRUNCATE, \
        ALTER or UPDATE statements. Do not run anything; you only write text.
        """
}

struct SchemaInfo { let name: String }
struct TableInfo { let name: String }
struct ColumnInfo { let name: String; let dataType: String }

@MainActor
final class MetadataCache {
    struct ConnectionMetadata {
        var schemas: [SchemaInfo] = []
        var tables: [String: [TableInfo]] = [:]
        var columnsByTable: [String: [ColumnInfo]] = [:]
    }
}
