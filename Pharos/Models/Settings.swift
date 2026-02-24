import Foundation

enum ThemeMode: String, Codable {
    case light, dark, auto
}

enum NullDisplay: String, Codable, CaseIterable {
    case uppercase = "NULL"
    case lowercase = "null"
    case parenthesized = "(null)"
    case dash = "—"
    case emptySet = "∅"

    var displayLabel: String {
        switch self {
        case .uppercase: return "NULL"
        case .lowercase: return "null"
        case .parenthesized: return "(null)"
        case .dash: return "— (em dash)"
        case .emptySet: return "∅ (empty set)"
        }
    }
}

enum BoolDisplay: String, Codable, CaseIterable {
    case trueFalse = "trueFalse"
    case trueFalseLower = "trueFalseLower"
    case pgDefault = "pgDefault"
    case yesNo = "yesNo"
    case oneZero = "oneZero"
    case symbols = "symbols"

    var trueString: String {
        switch self {
        case .trueFalse: return "TRUE"
        case .trueFalseLower: return "true"
        case .pgDefault: return "t"
        case .yesNo: return "Yes"
        case .oneZero: return "1"
        case .symbols: return "✓"
        }
    }

    var falseString: String {
        switch self {
        case .trueFalse: return "FALSE"
        case .trueFalseLower: return "false"
        case .pgDefault: return "f"
        case .yesNo: return "No"
        case .oneZero: return "0"
        case .symbols: return "✗"
        }
    }

    var displayLabel: String {
        "\(trueString) / \(falseString)"
    }
}

struct EditorSettings: Codable {
    var fontSize: UInt32 = 13
    var fontFamily: String = "JetBrains Mono, Monaco, Menlo, monospace"
    var tabSize: UInt32 = 2
    var wordWrap: Bool = false
    var minimap: Bool = false
    var lineNumbers: Bool = true
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

struct QuerySettings: Codable {
    var defaultLimit: UInt32 = 1000
    var timeoutSeconds: UInt32 = 30
    var autoCommit: Bool = true
    var confirmDestructive: Bool = true
}

struct UISettings: Codable {
    var navigatorWidth: UInt32 = 250
    var savedQueriesWidth: UInt32 = 250
    var resultsPanelHeight: UInt32 = 300
    var editorSplitPosition: UInt32 = 50
}

struct KeyboardShortcut: Codable {
    var id: String
    var label: String
    var description: String
    var key: String
    var modifiers: [String]
}

struct KeyboardSettings: Codable {
    var shortcuts: [KeyboardShortcut] = []
}

struct AppSettings: Codable {
    var theme: ThemeMode = .auto
    var editor: EditorSettings = EditorSettings()
    var query: QuerySettings = QuerySettings()
    var ui: UISettings = UISettings()
    var keyboard: KeyboardSettings = KeyboardSettings()
    var emptyFolders: [String] = []
    var nullDisplay: NullDisplay = .uppercase
    var boolDisplay: BoolDisplay = .trueFalse
}
