use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ThemeMode {
    Light,
    Dark,
    Auto,
}

impl Default for ThemeMode {
    fn default() -> Self {
        ThemeMode::Auto
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum NullDisplay {
    #[serde(rename = "NULL")]
    Uppercase,
    #[serde(rename = "null")]
    Lowercase,
    #[serde(rename = "(null)")]
    Parenthesized,
    #[serde(rename = "—")]
    Dash,
    #[serde(rename = "∅")]
    EmptySet,
}

impl Default for NullDisplay {
    fn default() -> Self {
        NullDisplay::Uppercase
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum BoolDisplay {
    #[serde(rename = "trueFalse")]
    TrueFalse,
    #[serde(rename = "trueFalseLower")]
    TrueFalseLower,
    #[serde(rename = "pgDefault")]
    PgDefault,
    #[serde(rename = "yesNo")]
    YesNo,
    #[serde(rename = "oneZero")]
    OneZero,
    #[serde(rename = "symbols")]
    Symbols,
}

impl Default for BoolDisplay {
    fn default() -> Self {
        BoolDisplay::TrueFalse
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EditorSettings {
    #[serde(default = "default_font_size")]
    pub font_size: u32,
    #[serde(default = "default_font_family")]
    pub font_family: String,
    #[serde(default = "default_tab_size")]
    pub tab_size: u32,
    #[serde(default)]
    pub word_wrap: bool,
    #[serde(default = "default_line_numbers")]
    pub line_numbers: bool,

    // Text
    #[serde(default = "default_true")]
    pub insert_spaces_for_tab: bool,
    #[serde(default = "default_true")]
    pub auto_indent: bool,
    #[serde(default = "default_true")]
    pub auto_pair_brackets: bool,
    #[serde(default = "default_true")]
    pub auto_pair_quotes: bool,
    #[serde(default = "default_true")]
    pub highlight_current_line: bool,
    #[serde(default = "default_true")]
    pub show_run_buttons_in_gutter: bool,
    #[serde(default = "default_true")]
    pub code_folding: bool,
    #[serde(default = "default_minimum_lines_to_fold")]
    pub minimum_lines_to_fold: u32,

    // Completion
    #[serde(default)]
    pub completion_trigger: CompletionTrigger,
    #[serde(default = "default_completion_minimum_characters")]
    pub completion_minimum_characters: u32,
    #[serde(default = "default_completion_maximum_items")]
    pub completion_maximum_items: u32,
    #[serde(default)]
    pub completion_keyword_case: KeywordCase,

    // Paste
    #[serde(default = "default_true")]
    pub offer_sql_list_chip: bool,
    #[serde(default)]
    pub sql_list_quote_style: SqlListQuoteStyle,

    // Colours
    #[serde(default = "default_syntax_theme")]
    pub syntax_theme: String,
}

/// When the completion list opens on its own. `AfterDot` is what the editor
/// did before the setting existed.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CompletionTrigger {
    Off,
    #[default]
    AfterDot,
    AfterDotAndIdentifiers,
}

/// The case a keyword takes as the completion list inserts it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum KeywordCase {
    #[default]
    Upper,
    Lower,
    MatchTyping,
}

/// How "Format as SQL list" wraps a value it quotes.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SqlListQuoteStyle {
    #[default]
    Single,
    Double,
    None,
}

fn default_font_size() -> u32 { 13 }
fn default_font_family() -> String { "JetBrains Mono, Monaco, Menlo, monospace".to_string() }
fn default_tab_size() -> u32 { 2 }
fn default_line_numbers() -> bool { true }
fn default_minimum_lines_to_fold() -> u32 { 3 }
fn default_completion_minimum_characters() -> u32 { 1 }
fn default_completion_maximum_items() -> u32 { 200 }
fn default_syntax_theme() -> String { "system".to_string() }

impl Default for EditorSettings {
    fn default() -> Self {
        EditorSettings {
            font_size: default_font_size(),
            font_family: default_font_family(),
            tab_size: default_tab_size(),
            word_wrap: false,
            line_numbers: default_line_numbers(),
            insert_spaces_for_tab: true,
            auto_indent: true,
            auto_pair_brackets: true,
            auto_pair_quotes: true,
            highlight_current_line: true,
            show_run_buttons_in_gutter: true,
            code_folding: true,
            minimum_lines_to_fold: default_minimum_lines_to_fold(),
            completion_trigger: CompletionTrigger::default(),
            completion_minimum_characters: default_completion_minimum_characters(),
            completion_maximum_items: default_completion_maximum_items(),
            completion_keyword_case: KeywordCase::default(),
            offer_sql_list_chip: true,
            sql_list_quote_style: SqlListQuoteStyle::default(),
            syntax_theme: default_syntax_theme(),
        }
    }
}

/// What Cmd+Return runs (Settings ▸ Query ▸ Run).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RunScope {
    #[default]
    StatementAtCursor,
    SelectionElseStatement,
    WholeBuffer,
}

/// How loudly a failed query interrupts (Settings ▸ Query ▸ Errors).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FailureAlertStyle {
    #[default]
    Sheet,
    Banner,
    Notification,
    Silent,
}

/// When the error sheet opens by itself (Settings ▸ Query ▸ Errors).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ErrorSheetTrigger {
    FirstFailure,
    /// Today's behaviour: the first unread failure gets the inline banner.
    #[default]
    SecondFailure,
    Never,
}

/// Which kinds of database-changing statement ask for confirmation.
///
/// A struct of named bools, not a set: a Swift `Set` encodes in hash order,
/// so the stored JSON would differ between launches and the settings blob
/// would look changed when nothing had changed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DestructiveConfirmations {
    #[serde(default = "yes")]
    pub drop_object: bool,
    #[serde(default = "yes")]
    pub alter: bool,
    #[serde(default = "yes")]
    pub truncate: bool,
    #[serde(default = "yes")]
    pub delete: bool,
    #[serde(default = "yes")]
    pub update: bool,
    #[serde(default = "yes")]
    pub insert: bool,
    #[serde(default = "yes")]
    pub grant: bool,
}

fn yes() -> bool { true }

impl Default for DestructiveConfirmations {
    fn default() -> Self {
        DestructiveConfirmations {
            drop_object: true,
            alter: true,
            truncate: true,
            delete: true,
            update: true,
            insert: true,
            grant: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuerySettings {
    #[serde(default = "default_default_limit")]
    pub default_limit: u32,
    #[serde(default = "default_timeout_seconds")]
    pub timeout_seconds: u32,
    #[serde(default = "default_confirm_destructive")]
    pub confirm_destructive: bool,
    #[serde(default = "default_notify_when_app_inactive")]
    pub notify_when_app_inactive: bool,
    #[serde(default = "default_notify_when_background_tab")]
    pub notify_when_background_tab: bool,
    #[serde(default = "default_notify_min_duration_seconds")]
    pub notify_min_duration_seconds: u32,
    /// Whether a query the user cancelled opens the error sheet. The failure is
    /// recorded on its tab either way; this only decides whether the app
    /// interrupts the user.
    #[serde(default = "default_show_cancelled_query_dialog")]
    pub show_cancelled_query_dialog: bool,
    /// Whether the tabs open at quit are put back at the next launch.
    #[serde(default = "default_restore_open_tabs")]
    pub restore_open_tabs: bool,
    #[serde(default)]
    pub run_scope: RunScope,
    #[serde(default)]
    pub destructive_confirmations: DestructiveConfirmations,
    #[serde(default)]
    pub failure_alert_style: FailureAlertStyle,
    #[serde(default)]
    pub error_sheet_trigger: ErrorSheetTrigger,
}

fn default_default_limit() -> u32 { 1000 }
fn default_timeout_seconds() -> u32 { 300 }
fn default_confirm_destructive() -> bool { true }
fn default_notify_when_app_inactive() -> bool { true }
fn default_notify_when_background_tab() -> bool { true }
fn default_notify_min_duration_seconds() -> u32 { 5 }
fn default_show_cancelled_query_dialog() -> bool { true }
fn default_restore_open_tabs() -> bool { true }

impl Default for QuerySettings {
    fn default() -> Self {
        QuerySettings {
            default_limit: default_default_limit(),
            timeout_seconds: default_timeout_seconds(),
            confirm_destructive: default_confirm_destructive(),
            notify_when_app_inactive: default_notify_when_app_inactive(),
            notify_when_background_tab: default_notify_when_background_tab(),
            notify_min_duration_seconds: default_notify_min_duration_seconds(),
            show_cancelled_query_dialog: default_show_cancelled_query_dialog(),
            restore_open_tabs: default_restore_open_tabs(),
            run_scope: RunScope::default(),
            destructive_confirmations: DestructiveConfirmations::default(),
            failure_alert_style: FailureAlertStyle::default(),
            error_sheet_trigger: ErrorSheetTrigger::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChartSettings {
    #[serde(default = "default_palette")]
    pub palette: Vec<String>,
}

fn default_palette() -> Vec<String> {
    vec![
        "#E12D48".into(), "#3E7CC4".into(), "#C9820E".into(),
        "#2A9C81".into(), "#9B57C9".into(), "#E05525".into(),
    ]
}

impl Default for ChartSettings {
    fn default() -> Self {
        ChartSettings { palette: default_palette() }
    }
}

/// How a NULL is set apart from a real value in the results grid.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum NullStyle {
    #[default]
    Italic,
    Dimmed,
    Plain,
}

/// How often the background update check runs. "Never" is the
/// `check_for_updates` master switch, not a variant here.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum UpdateFrequency {
    OnLaunch,
    #[default]
    Daily,
    Weekly,
}

/// Which releases the update check looks at.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum UpdateChannel {
    #[default]
    Stable,
    PreRelease,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSettings {
    #[serde(default)]
    pub check_frequency: UpdateFrequency,
    #[serde(default)]
    pub channel: UpdateChannel,
}

/// The results grid's own display settings.
/// How tall a results row is and how large its text.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ResultsDensity {
    Compact,
    #[default]
    Normal,
    Comfortable,
}

/// Which rules the results grid draws between cells.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ResultsGridLines {
    None,
    Horizontal,
    #[default]
    Both,
}

/// How a result column takes its width when the grid first builds it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ColumnWidthMode {
    #[default]
    FitContent,
    Fixed,
}

/// How the results Find field matches a cell.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FindMode {
    #[default]
    Contains,
    WholeWord,
    RegularExpression,
}

/// The format ⌘C writes in the results grid.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CopyFormat {
    #[default]
    Tsv,
    Csv,
    Markdown,
    SqlInsert,
    SqlWith,
}

/// The results grid's own display settings. Mirrors `ResultsSettings` in
/// `Pharos/Models/Settings.swift`; every field needs `#[serde(default)]` or a
/// blob written before it existed fails Swift's synthesized decode at launch.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ResultsSettings {
    #[serde(default)]
    pub null_style: NullStyle,

    // Grid
    #[serde(default)]
    pub density: ResultsDensity,
    #[serde(default = "default_true")]
    pub alternating_row_colors: bool,
    #[serde(default)]
    pub grid_lines: ResultsGridLines,
    #[serde(default = "default_results_font_size")]
    pub font_size: u32,
    #[serde(default = "default_true")]
    pub monospaced_font: bool,
    #[serde(default = "default_true")]
    pub show_row_numbers: bool,
    #[serde(default)]
    pub show_column_type_icons: bool,

    // Columns
    #[serde(default)]
    pub column_width_mode: ColumnWidthMode,
    #[serde(default = "default_maximum_column_width")]
    pub maximum_column_width: u32,
    #[serde(default = "default_fixed_column_width")]
    pub fixed_column_width: u32,

    // Cells
    #[serde(default)]
    pub maximum_cell_characters: u32,
    #[serde(default = "default_true")]
    pub escape_control_characters: bool,

    // Find
    #[serde(default)]
    pub find_mode: FindMode,
    #[serde(default)]
    pub find_match_case: bool,

    // Copy
    #[serde(default)]
    pub default_copy_format: CopyFormat,
    #[serde(default = "default_true")]
    pub copy_include_headers: bool,
    #[serde(default = "default_true")]
    pub copy_rich_text: bool,

    // Editing
    #[serde(default = "default_true")]
    pub allow_inline_editing: bool,

    // Result tabs
    #[serde(default)]
    pub maximum_result_tabs: u32,
    #[serde(default = "default_true")]
    pub show_result_tabs_panel_by_default: bool,
}

fn default_true() -> bool { true }
fn default_results_font_size() -> u32 { 12 }
fn default_maximum_column_width() -> u32 { 1000 }
fn default_fixed_column_width() -> u32 { 200 }

impl Default for ResultsSettings {
    fn default() -> Self {
        ResultsSettings {
            null_style: NullStyle::default(),
            density: ResultsDensity::default(),
            alternating_row_colors: true,
            grid_lines: ResultsGridLines::default(),
            font_size: default_results_font_size(),
            monospaced_font: true,
            show_row_numbers: true,
            show_column_type_icons: false,
            column_width_mode: ColumnWidthMode::default(),
            maximum_column_width: default_maximum_column_width(),
            fixed_column_width: default_fixed_column_width(),
            maximum_cell_characters: 0,
            escape_control_characters: true,
            find_mode: FindMode::default(),
            find_match_case: false,
            default_copy_format: CopyFormat::default(),
            copy_include_headers: true,
            copy_rich_text: true,
            allow_inline_editing: true,
            maximum_result_tabs: 0,
            show_result_tabs_panel_by_default: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(default)]
    pub theme: ThemeMode,
    #[serde(default)]
    pub editor: EditorSettings,
    #[serde(default)]
    pub query: QuerySettings,
    #[serde(default)]
    pub null_display: NullDisplay,
    #[serde(default)]
    pub bool_display: BoolDisplay,
    #[serde(default = "default_check_for_updates")]
    pub check_for_updates: bool,
    #[serde(default)]
    pub show_leaf_partitions: bool,
    #[serde(default = "default_vertical_result_tabs")]
    pub vertical_result_tabs: bool,
    /// Whether the on-device Apple Intelligence features are offered at all.
    /// Defaults ON: the model runs on this Mac and sends nothing anywhere, and
    /// a user who does not want it turns it off in Settings ▸ General.
    #[serde(default = "default_use_apple_intelligence")]
    pub use_apple_intelligence: bool,
    #[serde(default)]
    pub charts: ChartSettings,
    #[serde(default)]
    pub results: ResultsSettings,
    #[serde(default)]
    pub updates: UpdateSettings,
    /// Whether the editor and the results grid pin legacy scroll bars on
    /// screen. Defaults OFF — follow the system's scroll-bar preference, as
    /// the HIG asks — so a bare `#[serde(default)]` is the right default here.
    #[serde(default)]
    pub always_show_scroll_bars: bool,
}

fn default_check_for_updates() -> bool { true }
fn default_vertical_result_tabs() -> bool { true }
fn default_use_apple_intelligence() -> bool { true }

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            theme: ThemeMode::default(),
            editor: EditorSettings::default(),
            query: QuerySettings::default(),
            null_display: NullDisplay::default(),
            bool_display: BoolDisplay::default(),
            check_for_updates: default_check_for_updates(),
            show_leaf_partitions: false,
            vertical_result_tabs: default_vertical_result_tabs(),
            use_apple_intelligence: default_use_apple_intelligence(),
            charts: ChartSettings::default(),
            results: ResultsSettings::default(),
            updates: UpdateSettings::default(),
            always_show_scroll_bars: false,
        }
    }
}

/// Fixtures shared with the Swift side.
///
/// `scripts/test-settings-decode.sh` feeds `PharosTests/Fixtures/settings-default.json`
/// and `settings-nondefault.json` to Swift's synthesized decoder. The two files
/// are GENERATED from this module (`scripts/gen-settings-fixture.sh`) and the
/// tests below fail when the struct and the committed files drift apart, so a
/// field added on one side of the FFI without the other is caught in `cargo
/// test`, not at the user's next launch.
#[cfg(test)]
pub(crate) mod fixture {
    use super::*;
    use serde_json::Value;

    const FIXTURE_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../PharosTests/Fixtures");

    impl AppSettings {
        /// Every bool flipped, every enum moved off its default, every number
        /// +1, every string changed. Exercises the value path of each field,
        /// where the default fixture only exercises the key.
        pub fn sample_non_default() -> AppSettings {
            AppSettings {
                theme: ThemeMode::Dark,
                editor: EditorSettings {
                    font_size: 14,
                    font_family: "Menlo".to_string(),
                    tab_size: 3,
                    word_wrap: true,
                    line_numbers: false,
                    insert_spaces_for_tab: false,
                    auto_indent: false,
                    auto_pair_brackets: false,
                    auto_pair_quotes: false,
                    highlight_current_line: false,
                    show_run_buttons_in_gutter: false,
                    code_folding: false,
                    minimum_lines_to_fold: 4,
                    completion_trigger: CompletionTrigger::AfterDotAndIdentifiers,
                    completion_minimum_characters: 2,
                    completion_maximum_items: 201,
                    completion_keyword_case: KeywordCase::Lower,
                    offer_sql_list_chip: false,
                    sql_list_quote_style: SqlListQuoteStyle::Double,
                    syntax_theme: "vivid".to_string(),
                },
                query: QuerySettings {
                    default_limit: 1001,
                    timeout_seconds: 301,
                    confirm_destructive: false,
                    notify_when_app_inactive: false,
                    notify_when_background_tab: false,
                    notify_min_duration_seconds: 6,
                    show_cancelled_query_dialog: false,
                    restore_open_tabs: false,
                    run_scope: RunScope::WholeBuffer,
                    destructive_confirmations: DestructiveConfirmations {
                        drop_object: false,
                        alter: false,
                        truncate: false,
                        delete: false,
                        update: false,
                        insert: false,
                        grant: false,
                    },
                    failure_alert_style: FailureAlertStyle::Silent,
                    error_sheet_trigger: ErrorSheetTrigger::Never,
                },
                null_display: NullDisplay::Lowercase,
                bool_display: BoolDisplay::YesNo,
                check_for_updates: false,
                show_leaf_partitions: true,
                vertical_result_tabs: false,
                use_apple_intelligence: false,
                charts: ChartSettings { palette: vec!["#000000".to_string()] },
                results: ResultsSettings {
                    null_style: NullStyle::Dimmed,
                    density: ResultsDensity::Comfortable,
                    alternating_row_colors: false,
                    grid_lines: ResultsGridLines::Horizontal,
                    font_size: 13,
                    monospaced_font: false,
                    show_row_numbers: false,
                    show_column_type_icons: true,
                    column_width_mode: ColumnWidthMode::Fixed,
                    maximum_column_width: 1001,
                    fixed_column_width: 201,
                    maximum_cell_characters: 1,
                    escape_control_characters: false,
                    find_mode: FindMode::RegularExpression,
                    find_match_case: true,
                    default_copy_format: CopyFormat::Markdown,
                    copy_include_headers: false,
                    copy_rich_text: false,
                    allow_inline_editing: false,
                    maximum_result_tabs: 1,
                    show_result_tabs_panel_by_default: false,
                },
                updates: UpdateSettings {
                    check_frequency: UpdateFrequency::Weekly,
                    channel: UpdateChannel::PreRelease,
                },
                always_show_scroll_bars: true,
            }
        }
    }

    fn to_value(settings: &AppSettings) -> Value {
        serde_json::to_value(settings).expect("AppSettings serializes")
    }

    fn fixture_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(FIXTURE_DIR).join(name)
    }

    fn read_fixture(name: &str) -> Value {
        let path = fixture_path(name);
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!("cannot read {}: {} — run scripts/gen-settings-fixture.sh", path.display(), e)
        });
        serde_json::from_str(&text).unwrap_or_else(|e| panic!("{} is not JSON: {}", path.display(), e))
    }

    fn pretty(value: &Value) -> String {
        let mut text = serde_json::to_string_pretty(value).expect("pretty JSON");
        text.push('\n');
        text
    }

    /// The committed default fixture is what `AppSettings::default()` writes today.
    #[test]
    fn default_fixture_is_current() {
        assert_eq!(
            read_fixture("settings-default.json"),
            to_value(&AppSettings::default()),
            "settings-default.json has drifted — run scripts/gen-settings-fixture.sh"
        );
    }

    /// The committed non-default fixture is what `sample_non_default()` writes today.
    #[test]
    fn nondefault_fixture_is_current() {
        assert_eq!(
            read_fixture("settings-nondefault.json"),
            to_value(&AppSettings::sample_non_default()),
            "settings-nondefault.json has drifted — run scripts/gen-settings-fixture.sh"
        );
    }

    /// Every top-level and second-level key carries `#[serde(default)]`: a blob
    /// written before the key existed must decode to the default value for it.
    #[test]
    fn every_key_can_be_absent() {
        let full = to_value(&AppSettings::default());
        let top = full.as_object().expect("object");
        assert!(!top.is_empty());
        for (key, value) in top {
            let mut without = full.clone();
            without.as_object_mut().unwrap().remove(key);
            let parsed: AppSettings = serde_json::from_value(without)
                .unwrap_or_else(|e| panic!("blob without top-level `{}` must parse: {}", key, e));
            assert_eq!(parsed, AppSettings::default(), "absent `{}` must give the default", key);

            if let Some(nested) = value.as_object() {
                for inner in nested.keys() {
                    let mut without_inner = full.clone();
                    without_inner[key].as_object_mut().unwrap().remove(inner);
                    let parsed: AppSettings = serde_json::from_value(without_inner)
                        .unwrap_or_else(|e| panic!("blob without `{}.{}` must parse: {}", key, inner, e));
                    assert_eq!(parsed, AppSettings::default(), "absent `{}.{}` must give the default", key, inner);
                }
            }
        }
    }

    /// The non-default sample survives serialize → deserialize unchanged, and
    /// really differs from the default in every top-level key (so the Swift
    /// re-encode test exercises every value, not only every key).
    #[test]
    fn non_default_sample_round_trips() {
        let sample = AppSettings::sample_non_default();
        let text = serde_json::to_string(&sample).expect("serializes");
        let back: AppSettings = serde_json::from_str(&text).expect("parses");
        assert_eq!(back, sample);

        let default = to_value(&AppSettings::default());
        let non_default = to_value(&sample);
        for (key, value) in non_default.as_object().unwrap() {
            assert_ne!(value, &default[key], "sample_non_default leaves `{}` at its default", key);
        }
    }

    /// Writes both fixture files. A no-op unless `PHAROS_PRINT_FIXTURE=1`, so
    /// a plain `cargo test` never touches the repository.
    #[test]
    fn print_fixtures() {
        if std::env::var("PHAROS_PRINT_FIXTURE").map(|v| v == "1").unwrap_or(false) == false {
            return;
        }
        std::fs::create_dir_all(FIXTURE_DIR).expect("fixture dir");
        for (name, settings) in [
            ("settings-default.json", AppSettings::default()),
            ("settings-nondefault.json", AppSettings::sample_non_default()),
        ] {
            let path = fixture_path(name);
            std::fs::write(&path, pretty(&to_value(&settings))).expect("write fixture");
            println!("wrote {}", path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Settings stored before this field existed must still load. Without the
    /// serde default, the whole settings blob fails to parse and the app falls
    /// back to defaults for everything.
    #[test]
    fn query_settings_default_show_cancelled_query_dialog() {
        let json = r#"{
            "defaultLimit": 500,
            "timeoutSeconds": 30,
            "confirmDestructive": true
        }"#;
        let parsed: QuerySettings = serde_json::from_str(json).expect("old settings must still parse");
        assert_eq!(parsed.default_limit, 500);
        assert!(parsed.show_cancelled_query_dialog, "the field defaults to true");
    }

    /// Settings stored before this field existed must still load, and the
    /// field must default ON — bare #[serde(default)] would yield false and
    /// silently flip existing users to the horizontal bar.
    #[test]
    fn app_settings_default_vertical_result_tabs() {
        // A realistic blob from an older build. None of these keys is what
        // this test checks — the subject is the ABSENT `verticalResultTabs`
        // key, and nothing here asserts on these values.
        let json = r#"{
            "theme": "auto",
            "editor": {"fontFamily": "Menlo", "fontSize": 13, "tabSize": 2, "lineNumbers": true, "wordWrap": false},
            "query": {"defaultLimit": 500, "timeoutSeconds": 30, "confirmDestructive": true}
        }"#;
        let parsed: AppSettings = serde_json::from_str(json).expect("old settings must still parse");
        // Two separate code paths, each hand-written and each able to regress
        // alone: the serde attribute, then the Default impl.
        assert!(parsed.vertical_result_tabs, "the serde default gives true");
        assert!(AppSettings::default().vertical_result_tabs, "the Default impl also gives true");
    }

    /// Settings stored before the Apple Intelligence switch existed must load
    /// with it ON. A bare `#[serde(default)]` would give `false` and take the
    /// features away from every existing user without them asking.
    ///
    /// The Swift side has no `decodeIfPresent`: it decodes the object the core
    /// re-serializes, so this default is also what puts the key on the wire at
    /// all. Losing it makes Swift's synthesized decode THROW.
    #[test]
    fn app_settings_default_use_apple_intelligence() {
        let json = r#"{
            "theme": "auto",
            "query": {"defaultLimit": 500}
        }"#;
        let parsed: AppSettings = serde_json::from_str(json).expect("old settings must still parse");
        assert!(parsed.use_apple_intelligence, "the serde default gives true");
        assert!(AppSettings::default().use_apple_intelligence, "the Default impl also gives true");

        // The key must survive a round trip, under the camelCase name Swift
        // decodes. `rename_all` is what produces it, and a struct-level
        // attribute is easy to lose in a merge.
        let re_serialized = serde_json::to_string(&parsed).expect("must re-serialize");
        assert!(
            re_serialized.contains("\"useAppleIntelligence\":true"),
            "the key crosses the FFI camelCased: {}",
            re_serialized
        );

        // And a stored `false` must not be silently turned back on.
        let off: AppSettings =
            serde_json::from_str(r#"{"useAppleIntelligence": false}"#).expect("must parse");
        assert!(!off.use_apple_intelligence, "a stored refusal is honoured");
    }

    /// Settings stored before the scroll-bar switch existed must load with it
    /// OFF (follow the system), the key must cross the FFI camelCased — Swift's
    /// synthesized decode THROWS on a missing key — and a stored `true` must
    /// survive the round trip.
    #[test]
    fn app_settings_default_always_show_scroll_bars() {
        let parsed: AppSettings = serde_json::from_str(r#"{"theme": "auto"}"#).expect("old settings must still parse");
        assert!(!parsed.always_show_scroll_bars, "the serde default is off: follow the system");
        assert!(!AppSettings::default().always_show_scroll_bars, "the Default impl also gives off");

        let re_serialized = serde_json::to_string(&parsed).expect("must re-serialize");
        assert!(
            re_serialized.contains("\"alwaysShowScrollBars\":false"),
            "the key crosses the FFI camelCased: {}",
            re_serialized
        );

        let on: AppSettings = serde_json::from_str(r#"{"alwaysShowScrollBars": true}"#).expect("must parse");
        assert!(on.always_show_scroll_bars, "a stored on is honoured");
    }

    // One test per struct below. Each feeds an EMPTY object — the worst case
    // for a blob written by an older build — and asserts every field comes
    // back with the same value `impl Default` gives. A field that loses its
    // serde default fails the parse here instead of silently wiping the
    // user's settings at startup.

    #[test]
    fn editor_settings_parse_from_empty_object() {
        let parsed: EditorSettings = serde_json::from_str("{}").expect("an empty object must parse");
        let d = EditorSettings::default();
        assert_eq!(parsed.font_size, d.font_size);
        assert_eq!(parsed.font_family, d.font_family);
        assert_eq!(parsed.tab_size, d.tab_size);
        assert_eq!(parsed.word_wrap, d.word_wrap);
        assert_eq!(parsed.line_numbers, d.line_numbers);
        // The two values that must not be zero, spelled out so a change to
        // `impl Default` alone cannot make this test vacuous.
        assert_eq!(parsed.font_size, 13);
        assert!(parsed.line_numbers);
    }

    #[test]
    fn query_settings_parse_from_empty_object() {
        let parsed: QuerySettings = serde_json::from_str("{}").expect("an empty object must parse");
        let d = QuerySettings::default();
        assert_eq!(parsed.default_limit, d.default_limit);
        assert_eq!(parsed.timeout_seconds, d.timeout_seconds);
        assert_eq!(parsed.confirm_destructive, d.confirm_destructive);
        assert_eq!(parsed.notify_when_app_inactive, d.notify_when_app_inactive);
        assert_eq!(parsed.notify_when_background_tab, d.notify_when_background_tab);
        assert_eq!(parsed.notify_min_duration_seconds, d.notify_min_duration_seconds);
        assert_eq!(parsed.show_cancelled_query_dialog, d.show_cancelled_query_dialog);
        // A zero limit returns no rows and a zero timeout aborts every query.
        assert_eq!(parsed.default_limit, 1000);
        assert_eq!(parsed.timeout_seconds, 300);
        assert!(parsed.confirm_destructive, "the guard must not default OFF");
    }

    #[test]
    fn chart_settings_parse_from_empty_object() {
        let parsed: ChartSettings = serde_json::from_str("{}").expect("an empty object must parse");
        assert_eq!(parsed.palette, ChartSettings::default().palette);
        assert!(!parsed.palette.is_empty(), "an empty palette gives colourless charts");
    }

    #[test]
    fn app_settings_parse_from_empty_object() {
        // The whole blob, empty. This is what a settings row written before
        // any of these fields existed looks like to serde.
        let parsed: AppSettings = serde_json::from_str("{}").expect("an empty object must parse");
        let d = AppSettings::default();
        assert_eq!(parsed.theme, d.theme);
        assert_eq!(parsed.null_display, d.null_display);
        assert_eq!(parsed.bool_display, d.bool_display);
        assert_eq!(parsed.check_for_updates, d.check_for_updates);
        assert_eq!(parsed.show_leaf_partitions, d.show_leaf_partitions);
        assert_eq!(parsed.vertical_result_tabs, d.vertical_result_tabs);
        assert_eq!(parsed.use_apple_intelligence, d.use_apple_intelligence);
        assert_eq!(parsed.always_show_scroll_bars, d.always_show_scroll_bars);
        // The nested structs must also come back at their defaults.
        assert_eq!(parsed.editor.font_size, d.editor.font_size);
        assert_eq!(parsed.query.default_limit, d.query.default_limit);
        assert_eq!(parsed.charts.palette, d.charts.palette);
    }

    /// The failure this whole change prevents: a blob from an older build
    /// that keeps the user's own values but misses newer keys must load with
    /// the stored values INTACT. A parse error here would throw all of them
    /// away and silently reset the app to defaults.
    #[test]
    fn app_settings_keeps_stored_values_when_newer_keys_are_missing() {
        let json = r#"{
            "theme": "dark",
            "editor": {"fontSize": 18, "fontFamily": "Menlo"},
            "query": {"defaultLimit": 42}
        }"#;
        let parsed: AppSettings = serde_json::from_str(json).expect("old settings must still parse");
        // Stored values survive.
        assert_eq!(parsed.theme, ThemeMode::Dark);
        assert_eq!(parsed.editor.font_size, 18);
        assert_eq!(parsed.editor.font_family, "Menlo");
        assert_eq!(parsed.query.default_limit, 42);
        // Absent keys fall back, each on its own.
        assert_eq!(parsed.editor.tab_size, 2);
        assert!(parsed.editor.line_numbers);
        assert_eq!(parsed.query.timeout_seconds, 300);
        assert!(parsed.query.confirm_destructive);
    }

    /// Settings written by a build that still had `keyboard`, `ui`,
    /// `editor.minimap`, `query.autoCommit` and `emptyFolders` must still parse after those
    /// fields were removed (serde ignores unknown keys by default), the live
    /// keys in the same blob must survive, and re-serializing must not bring
    /// the removed keys back.
    #[test]
    fn app_settings_ignores_removed_keys_from_older_builds() {
        let json = r#"{
            "theme": "dark",
            "editor": {"fontSize": 18, "fontFamily": "Menlo", "minimap": true},
            "query": {"defaultLimit": 42, "autoCommit": false},
            "emptyFolders": ["a/b"],
            "ui": {"navigatorWidth": 400, "savedQueriesWidth": 200, "resultsPanelHeight": 320, "editorSplitPosition": 60},
            "keyboard": {"shortcuts": [{"id": "run-query", "label": "Run Query", "description": "Runs the current query", "key": "Return", "modifiers": ["cmd"]}]}
        }"#;
        let parsed: AppSettings =
            serde_json::from_str(json).expect("old settings with removed keys must still parse");

        // Live values in the same blob survive untouched.
        assert_eq!(parsed.theme, ThemeMode::Dark);
        assert_eq!(parsed.editor.font_size, 18);
        assert_eq!(parsed.editor.font_family, "Menlo");
        assert_eq!(parsed.query.default_limit, 42);

        // Re-serializing must not emit the removed keys.
        let re_serialized = serde_json::to_string(&parsed).expect("must re-serialize");
        assert!(!re_serialized.contains("\"ui\""), "removed `ui` key must not reappear");
        assert!(!re_serialized.contains("keyboard"), "removed `keyboard` key must not reappear");
        assert!(!re_serialized.contains("minimap"), "removed `minimap` key must not reappear");
        assert!(!re_serialized.contains("autoCommit"), "removed `autoCommit` key must not reappear");
        assert!(!re_serialized.contains("emptyFolders"), "removed `emptyFolders` key must not reappear");
    }
}
