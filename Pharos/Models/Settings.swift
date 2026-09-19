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

/// How a NULL is set apart from a real value in the results grid.
enum NullStyle: String, Codable, CaseIterable {
    case italic
    case dimmed
    case plain

    var displayLabel: String {
        switch self {
        case .italic: return String(localized: "Italic")
        case .dimmed: return String(localized: "Dimmed")
        case .plain: return String(localized: "Plain")
        }
    }
}

/// How often the background update check runs. "Never" is the
/// `checkForUpdates` master switch, not a case here.
enum UpdateFrequency: String, Codable, CaseIterable {
    case onLaunch
    case daily
    case weekly

    var displayLabel: String {
        switch self {
        case .onLaunch: return String(localized: "On launch only")
        case .daily: return String(localized: "Daily")
        case .weekly: return String(localized: "Weekly")
        }
    }

    /// The repeating timer's period. `onLaunch` never repeats.
    var repeatInterval: TimeInterval? {
        switch self {
        case .onLaunch: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }

    /// How stale a stored result may be before a non-forced check refetches.
    var cacheSeconds: TimeInterval {
        switch self {
        case .onLaunch: return 24 * 3600
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }
}

/// Which releases the update check looks at.
enum UpdateChannel: String, Codable, CaseIterable {
    case stable
    case preRelease

    var displayLabel: String {
        switch self {
        case .stable: return String(localized: "Stable")
        case .preRelease: return String(localized: "Pre-release")
        }
    }
}

struct UpdateSettings: Codable, Equatable {
    var checkFrequency: UpdateFrequency = .daily
    var channel: UpdateChannel = .stable
}

/// How tall a results row is and how large its text. Sits alongside the
/// explicit `ResultsSettings.fontSize` rather than replacing it: density is
/// the coarse "how much room does a row get", the size is the fine one.
enum ResultsDensity: String, Codable, CaseIterable {
    case compact
    case normal
    case comfortable

    var displayLabel: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .normal: return String(localized: "Normal")
        case .comfortable: return String(localized: "Comfortable")
        }
    }

    /// Added to `ResultsSettings.fontSize` before clamping to 9...18.
    var fontDelta: CGFloat {
        switch self {
        case .compact: return -1
        case .normal: return 0
        case .comfortable: return 1
        }
    }

    /// Room above and below the text, in points. `normal` at size 12 gives
    /// the 22pt row the grid used before this setting existed.
    var rowPadding: CGFloat {
        switch self {
        case .compact: return 6
        case .normal: return 10
        case .comfortable: return 16
        }
    }
}

/// Which rules the results grid draws between cells.
enum ResultsGridLines: String, Codable, CaseIterable {
    case none
    case horizontal
    case both

    var displayLabel: String {
        switch self {
        case .none: return String(localized: "None")
        case .horizontal: return String(localized: "Horizontal")
        case .both: return String(localized: "Both")
        }
    }
}

/// How a result column takes its width when the grid first builds it.
enum ColumnWidthMode: String, Codable, CaseIterable {
    case fitContent
    case fixed

    var displayLabel: String {
        switch self {
        case .fitContent: return String(localized: "Fit to content")
        case .fixed: return String(localized: "Fixed width")
        }
    }
}

/// How the results Find field matches a cell.
enum FindMode: String, Codable, CaseIterable {
    case contains
    case wholeWord
    case regularExpression

    var displayLabel: String {
        switch self {
        case .contains: return String(localized: "Contains")
        case .wholeWord: return String(localized: "Whole word")
        case .regularExpression: return String(localized: "Regular expression")
        }
    }
}

/// The format ⌘C writes. Exactly the five the grid's Copy menu offers —
/// JSON is an Export format only, so it is deliberately absent.
enum CopyFormat: String, Codable, CaseIterable {
    case tsv
    case csv
    case markdown
    case sqlInsert
    case sqlWith

    var displayLabel: String {
        switch self {
        case .tsv: return String(localized: "TSV")
        case .csv: return String(localized: "CSV")
        case .markdown: return String(localized: "Markdown")
        case .sqlInsert: return String(localized: "SQL INSERT")
        case .sqlWith: return String(localized: "SQL WITH")
        }
    }
}

/// The results grid's own display settings.
///
/// Every default here is what the grid did before the setting existed, so an
/// existing user sees no change until they touch a control.
struct ResultsSettings: Codable, Equatable {
    var nullStyle: NullStyle = .italic

    // MARK: Grid

    var density: ResultsDensity = .normal
    var alternatingRowColors: Bool = true
    var gridLines: ResultsGridLines = .both
    /// Body cell font size in points. 12 is what `ResultsGridMetrics.cellFont`
    /// was hard-coded to.
    var fontSize: UInt32 = 12
    var monospacedFont: Bool = true
    var showRowNumbers: Bool = true
    /// A type glyph beside the data type in the header's second row. Off is
    /// today's header, which shows the type as text only.
    var showColumnTypeIcons: Bool = false

    // MARK: Columns

    var columnWidthMode: ColumnWidthMode = .fitContent
    var maximumColumnWidth: UInt32 = 1000
    /// Used only while `columnWidthMode` is `.fixed`.
    var fixedColumnWidth: UInt32 = 200

    // MARK: Cells

    /// Longest display string a cell draws, 0 for no limit. Display only —
    /// copy, export, find and sort read the raw value.
    var maximumCellCharacters: UInt32 = 0
    /// Whether hostile scalars (bidi overrides, zero-width spaces, C0
    /// controls) are shown as `<U+XXXX>` instead of being obeyed by the label.
    var escapeControlCharacters: Bool = true

    // MARK: Find

    var findMode: FindMode = .contains
    var findMatchCase: Bool = false

    // MARK: Copy

    var defaultCopyFormat: CopyFormat = .tsv
    var copyIncludeHeaders: Bool = true
    /// Whether a copy also writes the `.html` rich-text flavour.
    var copyRichText: Bool = true

    // MARK: Editing

    var allowInlineEditing: Bool = true

    // MARK: Result tabs

    /// Most result tabs one editor tab keeps, 0 for unlimited.
    var maximumResultTabs: UInt32 = 0
    /// Whether a newly created editor tab opens with the result-tabs panel.
    var showResultTabsPanelByDefault: Bool = true
}

struct AppSettings: Codable, Equatable {
    var theme: ThemeMode = .auto
    var editor: EditorSettings = EditorSettings()
    var query: QuerySettings = QuerySettings()
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
    var results: ResultsSettings = ResultsSettings()
    var updates: UpdateSettings = UpdateSettings()
    /// Whether the editor and the results grid pin legacy scroll bars on
    /// screen. Off follows the system's scroll-bar preference (the HIG
    /// default); on is what the grid did unconditionally before this existed.
    /// Same belt-and-braces default as above: the key is always on the wire
    /// because the core carries `#[serde(default)]`.
    var alwaysShowScrollBars: Bool = false
}
