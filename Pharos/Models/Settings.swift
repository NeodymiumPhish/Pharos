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

struct EditorSettings: Codable, Equatable {
    var fontSize: UInt32 = 13
    var fontFamily: String = "JetBrains Mono, Monaco, Menlo, monospace"
    var tabSize: UInt32 = 2
    var wordWrap: Bool = false
    var lineNumbers: Bool = true
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

struct QuerySettings: Codable, Equatable {
    var defaultLimit: UInt32 = 1000
    var timeoutSeconds: UInt32 = 300
    var confirmDestructive: Bool = true
    var notifyWhenAppInactive: Bool = true
    var notifyWhenBackgroundTab: Bool = true
    var notifyMinDurationSeconds: UInt32 = 5
    /// Whether a query the user cancelled opens the error sheet. The failure is
    /// recorded on its tab either way.
    var showCancelledQueryDialog: Bool = true
    /// Whether the tabs open at quit are put back at the next launch.
    var restoreOpenTabs: Bool = true
}

struct ChartSettings: Codable, Equatable {
    var palette: [String] = ChartPalette.defaultHex
}

struct AppSettings: Codable, Equatable {
    var theme: ThemeMode = .auto
    var editor: EditorSettings = EditorSettings()
    var query: QuerySettings = QuerySettings()
    var emptyFolders: [String] = []
    var nullDisplay: NullDisplay = .uppercase
    var boolDisplay: BoolDisplay = .trueFalse
    var checkForUpdates: Bool = true
    var showLeafPartitions: Bool = false
    var verticalResultTabs: Bool = true
    /// Whether the on-device Apple Intelligence features are offered at all.
    ///
    /// The default here is a belt-and-braces copy of the core's own default:
    /// `AppSettings` uses Swift's synthesized `init(from:)`, which THROWS on a
    /// missing key rather than falling back to this value. The key is always
    /// present because the core re-serializes its own struct, where the field
    /// carries `#[serde(default = "default_use_apple_intelligence")]`.
    var useAppleIntelligence: Bool = true
    var charts: ChartSettings = ChartSettings()
    /// Whether the editor and the results grid pin legacy scroll bars on
    /// screen. Off follows the system's scroll-bar preference (the HIG
    /// default); on is what the grid did unconditionally before this existed.
    /// Same belt-and-braces default as above: the key is always on the wire
    /// because the core carries `#[serde(default)]`.
    var alwaysShowScrollBars: Bool = false
}
