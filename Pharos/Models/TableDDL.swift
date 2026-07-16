import Foundation

/// The three reconstructed CREATE TABLE DDL variants returned by the core.
struct TableDDL: Codable {
    let columnsOnly: String
    let withConstraints: String
    let full: String
}

/// Selectable level of DDL detail shown in the TableDDLSheet sidebar.
enum DDLDetailLevel: Int, CaseIterable {
    case columns = 0
    case constraints = 1
    case full = 2

    var title: String {
        switch self {
        case .columns: return "Columns"
        case .constraints: return "+ Constraints"
        case .full: return "Full (+ Indexes)"
        }
    }

    func ddl(from ddl: TableDDL) -> String {
        switch self {
        case .columns: return ddl.columnsOnly
        case .constraints: return ddl.withConstraints
        case .full: return ddl.full
        }
    }
}
