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

/// When the completion list opens on its own.
///
/// Ctrl+Space always opens it, whichever this says: the setting governs the
/// AUTOMATIC offer only. Read by `CompletionTriggerPolicy`.
enum CompletionTrigger: String, Codable, CaseIterable {
    /// Never on its own.
    case off
    /// Only straight after a `.` — what the editor did before this setting
    /// existed (`SQLTextView.didChangeText`).
    case afterDot
    /// After a `.`, and while an identifier is being typed.
    case afterDotAndIdentifiers

    var displayLabel: String {
        switch self {
        case .off: return String(localized: "Never")
        case .afterDot: return String(localized: "After a dot")
        case .afterDotAndIdentifiers: return String(localized: "After a dot, and while typing")
        }
    }
}

/// The case a SQL keyword takes when the completion list inserts it. Read by
/// `KeywordCasing`.
enum KeywordCase: String, Codable, CaseIterable {
    /// `SELECT` — what `SQLCompletionProvider.sqlKeywords` has always
    /// inserted, because every entry in that list is written in capitals.
    case upper
    /// `select`
    case lower
    /// Follow the case of what the user has typed so far.
    case matchTyping

    var displayLabel: String {
        switch self {
        case .upper: return String(localized: "UPPERCASE")
        case .lower: return String(localized: "lowercase")
        case .matchTyping: return String(localized: "Match what I type")
        }
    }
}

/// How "Format as SQL list" wraps a value it decides to quote. Read by
/// `SQLListFormatter.sqlize`.
enum SqlListQuoteStyle: String, Codable, CaseIterable {
    /// `'value'` — standard SQL, and what the formatter did before this
    /// setting existed.
    case single
    /// `"value"` — a quoted IDENTIFIER in Postgres, not a string. For a list
    /// of column or table names.
    case double
    /// No quoting at all. The values are written exactly as they are.
    case none

    var displayLabel: String {
        switch self {
        case .single: return String(localized: "Single quotes ('value')")
        case .double: return String(localized: "Double quotes (\"value\")")
        case .none: return String(localized: "No quotes")
        }
    }
}

/// The SQL editor's own settings.
///
/// Every default here is what the editor did before the setting existed, so an
/// existing user sees no change until they touch a control. The enum types
/// live beside the code that reads them: `CompletionTrigger` and `KeywordCase`
/// in `Pharos/Editor/`, `SqlListQuoteStyle` in `SQLListFormatter.swift`.
struct EditorSettings: Codable, Equatable {
    var fontSize: UInt32 = 13
    var fontFamily: String = "JetBrains Mono, Monaco, Menlo, monospace"
    var tabSize: UInt32 = 2
    var wordWrap: Bool = false
    var lineNumbers: Bool = true

    // MARK: Text

    /// Tab inserts `tabSize` spaces. Off inserts a real tab character.
    var insertSpacesForTab: Bool = true
    /// Return copies the current line's leading whitespace.
    var autoIndent: Bool = true
    /// Typing `(` or `[` also writes the closer.
    var autoPairBrackets: Bool = true
    /// Typing `'` also writes the closer.
    var autoPairQuotes: Bool = true
    /// A wash behind the line the caret is on.
    var highlightCurrentLine: Bool = true
    /// The gutter's statement bands, and the run glyph they carry.
    var showRunButtonsInGutter: Bool = true
    /// The fold chevrons, and folding at all.
    var codeFolding: Bool = true
    /// Shortest region the fold parser will offer, in lines.
    var minimumLinesToFold: UInt32 = 3

    // MARK: Completion

    /// When the list opens on its own. Ctrl+Space always opens it.
    var completionTrigger: CompletionTrigger = .afterDot
    /// Identifier characters needed before the identifier trigger fires. Read
    /// only while `completionTrigger` is `afterDotAndIdentifiers`.
    var completionMinimumCharacters: UInt32 = 1
    /// Most rows the list ever holds.
    var completionMaximumItems: UInt32 = 200
    /// The case a keyword takes as it is inserted.
    var completionKeywordCase: KeywordCase = .upper

    // MARK: Paste

    /// Whether a paste that looks like a bare value list offers the
    /// "Format as SQL list" chip.
    var offerSqlListChip: Bool = true
    /// How that formatter quotes a value.
    var sqlListQuoteStyle: SqlListQuoteStyle = .single

    // MARK: Colours

    /// A name from `SQLTheme.catalog`. An unknown name reads as the System
    /// theme. Spelled out rather than referring to `SQLTheme.systemThemeName`
    /// so this file keeps compiling with Foundation alone
    /// (`scripts/test-settings-decode.sh`); `SQLThemeCatalogTests` pins the
    /// two spellings together.
    var syntaxTheme: String = "system"

    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

/// What ⌘↩ runs (Settings ▸ Query ▸ Run).
enum RunScope: String, Codable, CaseIterable {
    /// The statement the cursor is in. What Pharos has always done.
    case statementAtCursor
    /// The selected text; with nothing selected, the statement at the cursor.
    case selectionElseStatement
    /// Everything in the editor, as one statement.
    case wholeBuffer

    var displayLabel: String {
        switch self {
        case .statementAtCursor: return String(localized: "The statement at the cursor")
        case .selectionElseStatement: return String(localized: "The selection, else the statement")
        case .wholeBuffer: return String(localized: "The whole editor")
        }
    }
}

/// How a failed query interrupts the user (Settings ▸ Query ▸ Errors).
enum FailureAlertStyle: String, Codable, CaseIterable {
    /// The sheet, as soon as the rule below says so.
    case sheet
    /// The inline banner only. The sheet still opens from the error badge.
    case banner
    /// A macOS notification, and nothing on the window.
    case notification
    /// Nothing at all. The failure is still recorded on its tab.
    case silent

    var displayLabel: String {
        switch self {
        case .sheet: return String(localized: "Open the error sheet")
        case .banner: return String(localized: "Show a banner")
        case .notification: return String(localized: "Post a notification")
        case .silent: return String(localized: "Say nothing")
        }
    }
}

/// When the error sheet opens by itself (Settings ▸ Query ▸ Errors).
enum ErrorSheetTrigger: String, Codable, CaseIterable {
    /// The first failure the user has not read.
    case firstFailure
    /// Only once a second unread failure arrives. Today's behaviour.
    case secondFailure
    /// Never by itself; the error badge still opens it.
    case never

    var displayLabel: String {
        switch self {
        case .firstFailure: return String(localized: "The first failure")
        case .secondFailure: return String(localized: "The second failure")
        case .never: return String(localized: "Never")
        }
    }
}

/// Which kinds of database-changing statement ask for confirmation
/// (Settings ▸ Query ▸ Safety), when the master switch is on.
///
/// A struct of named bools rather than a `Set<String>`: a Swift `Set` encodes
/// in hash order, so the stored JSON would differ between launches and the
/// settings blob would look changed when nothing had changed.
struct DestructiveConfirmations: Codable, Equatable {
    /// DROP — an object is destroyed.
    var dropObject: Bool = true
    /// ALTER — an object's shape changes.
    var alter: Bool = true
    /// TRUNCATE — every row goes, without a WHERE to get wrong.
    var truncate: Bool = true
    /// DELETE — rows go.
    var delete: Bool = true
    /// UPDATE — rows change.
    var update: Bool = true
    /// INSERT — rows arrive.
    var insert: Bool = true
    /// GRANT / REVOKE — who may do what changes.
    var grant: Bool = true

    /// Whether a keyword the scanner found should raise the confirmation.
    /// The keyword arrives uppercased, as `DestructiveSQLScanner` returns it.
    func confirms(_ keyword: String) -> Bool {
        switch keyword {
        case "DROP": return dropObject
        case "ALTER": return alter
        case "TRUNCATE": return truncate
        case "DELETE": return delete
        case "UPDATE": return update
        case "INSERT": return insert
        case "GRANT", "REVOKE": return grant
        // A keyword the scanner knows and this struct does not is confirmed.
        // Failing safe is the only tolerable direction here: the alternative
        // is a statement that changes the database running with no warning
        // because someone added a keyword on one side only.
        default: return true
        }
    }

    /// The keywords of `found` that the user still wants to be asked about.
    func filtered(_ found: [String]) -> [String] {
        found.filter(confirms)
    }
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

    /// What Cmd+Return runs.
    var runScope: RunScope = .statementAtCursor
    /// Which kinds of database-changing statement ask for confirmation, when
    /// `confirmDestructive` is on.
    var destructiveConfirmations: DestructiveConfirmations = DestructiveConfirmations()
    /// How loudly a failed query interrupts.
    var failureAlertStyle: FailureAlertStyle = .sheet
    /// When the error sheet opens by itself.
    var errorSheetTrigger: ErrorSheetTrigger = .secondFailure
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
