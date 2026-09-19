use serde::{Deserialize, Serialize};

use crate::models::export_import::{CsvDialect, ExportFormat, ImportErrorPolicy};

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

    // Format SQL. Every default is what `pharos_format_sql` was hard-coded
    // to before these existed, so an existing user's Format button is
    // byte-for-byte unchanged until they touch a control.
    #[serde(default = "default_format_indent_width")]
    pub format_indent_width: u32,
    #[serde(default = "default_true")]
    pub format_uppercase_keywords: bool,
    #[serde(default = "default_format_lines_between_statements")]
    pub format_lines_between_statements: u32,
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
fn default_format_indent_width() -> u32 { 2 }
fn default_format_lines_between_statements() -> u32 { 2 }

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
            format_indent_width: default_format_indent_width(),
            format_uppercase_keywords: true,
            format_lines_between_statements: default_format_lines_between_statements(),
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

/// The per-feature switches under Settings ▸ Intelligence. All default ON:
/// every one of these ran whenever `use_apple_intelligence` allowed it before
/// the switches existed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct IntelligenceSettings {
    #[serde(default = "default_true")]
    pub describe_query: bool,
    #[serde(default = "default_true")]
    pub explain_errors: bool,
    #[serde(default = "default_true")]
    pub suggest_saved_query_names: bool,
    #[serde(default = "default_true")]
    pub name_tabs_automatically: bool,
    #[serde(default = "default_true")]
    pub summarise_plans: bool,
    #[serde(default = "default_true")]
    pub suggest_charts: bool,
    #[serde(default = "default_true")]
    pub allow_drafting_write_statements: bool,
}

impl Default for IntelligenceSettings {
    fn default() -> Self {
        IntelligenceSettings {
            describe_query: true,
            explain_errors: true,
            suggest_saved_query_names: true,
            name_tabs_automatically: true,
            summarise_plans: true,
            suggest_charts: true,
            allow_drafting_write_statements: true,
        }
    }
}

/// How long a toast stays on screen.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ToastDuration {
    Short,
    #[default]
    Normal,
    Long,
}

/// Sound, Dock badge and toast duration. Both bools default ON: that is what
/// Pharos did unconditionally before the settings existed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSettings {
    #[serde(default = "default_true")]
    pub play_sound: bool,
    #[serde(default = "default_true")]
    pub badge_dock_icon: bool,
    #[serde(default)]
    pub toast_duration: ToastDuration,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        NotificationSettings {
            play_sound: true,
            badge_dock_icon: true,
            toast_duration: ToastDuration::default(),
        }
    }
}

/// Settings ▸ Advanced.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsSettings {
    /// Minutes before cached schema metadata is refetched. 0 = never expire,
    /// which is what the Swift `MetadataCache` did before this existed.
    #[serde(default)]
    pub metadata_cache_ttl_minutes: u32,
    /// How much the engine writes to the system log. `Warning` is what
    /// `pharos_init` capped `env_logger` to before this existed.
    #[serde(default)]
    pub log_level: LogLevel,
}

/// How much pharos-core writes to the log. Applied through
/// `pharos_set_log_level`, which `RUST_LOG` overrides outright.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum LogLevel {
    Error,
    /// What the engine has always been capped at.
    #[default]
    Warning,
    Info,
    Debug,
}

/// Settings ▸ Security & Privacy. Both default ON: the Spotlight indexer and
/// the MetricKit subscriber both started at launch before these existed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SecuritySettings {
    #[serde(default = "default_true")]
    pub index_saved_queries_in_spotlight: bool,
    #[serde(default = "default_true")]
    pub collect_performance_metrics: bool,
}

impl Default for SecuritySettings {
    fn default() -> Self {
        SecuritySettings {
            index_saved_queries_in_spotlight: true,
            collect_performance_metrics: true,
        }
    }
}

/// How the app remembers a working session between launches.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionSettings {
    /// Seconds between automatic session snapshots. 0 turns autosave off.
    #[serde(default = "default_autosave_interval")]
    pub autosave_interval_seconds: u32,
    #[serde(default = "yes")]
    pub restore_window_frames: bool,
    #[serde(default = "default_editor_split_ratio")]
    pub default_editor_split_ratio: f64,
}

fn default_autosave_interval() -> u32 { 30 }
fn default_editor_split_ratio() -> f64 { 0.6 }

impl Default for SessionSettings {
    fn default() -> Self {
        SessionSettings {
            autosave_interval_seconds: default_autosave_interval(),
            restore_window_frames: true,
            default_editor_split_ratio: default_editor_split_ratio(),
        }
    }
}

// MARK: - Connections

/// Settings ▸ Connections. What a NEW connection starts as, and what every
/// pool the app opens is tuned to.
///
/// Every default here is what the app did before this struct existed, read
/// from the code that hard-coded it:
///
///  * `default_port` — `ConnectionsManagerVC.addStub`'s `port: 5432`.
///  * `search_path_suffix` — the `, public` in `commands::query::set_search_path`.
///  * `max_connections`, `connect_timeout_seconds`, `idle_timeout_seconds`,
///    `max_lifetime_seconds` — `db::postgres::pool_options` and `CONNECT_BUDGET`.
///  * `idle_in_transaction_seconds` — the `SET idle_in_transaction_session_timeout
///    = '30s'` that `create_pool_with_session` ran on one connection of the pool.
///
/// `application_name` and `default_time_zone` are empty by default, and empty
/// means "what the app sent before": no `application_name` parameter at all
/// (libpq then reports the process name) and the server's own `TimeZone`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionSettings {
    /// The port the Connections Manager fills in for a NEW connection.
    #[serde(default = "default_connection_port")]
    pub default_port: u32,
    /// `application_name`, which is what `pg_stat_activity` shows. Empty means
    /// `Pharos <version>` — see `ConnectionSettings::effective_application_name`.
    #[serde(default)]
    pub application_name: String,
    /// What follows the chosen schema in `search_path`. Empty means the schema
    /// alone. Commas separate several, and each element is quoted.
    #[serde(default = "default_search_path_suffix")]
    pub search_path_suffix: String,
    /// Connections in one pool.
    #[serde(default = "default_max_connections")]
    pub max_connections: u32,
    /// The whole budget for one connect attempt, in seconds.
    #[serde(default = "default_connect_timeout_seconds")]
    pub connect_timeout_seconds: u32,
    /// How long an unused pooled connection is kept, in seconds.
    #[serde(default = "default_idle_timeout_seconds")]
    pub idle_timeout_seconds: u32,
    /// The longest a pooled connection lives, in seconds.
    #[serde(default = "default_max_lifetime_seconds")]
    pub max_lifetime_seconds: u32,
    /// `idle_in_transaction_session_timeout`, in seconds. 0 turns it off.
    #[serde(default = "default_idle_in_transaction_seconds")]
    pub idle_in_transaction_seconds: u32,
    /// `tcp_keepalives_idle`, in seconds. 0 leaves the server's own.
    #[serde(default)]
    pub keepalive_idle_seconds: u32,
    /// `tcp_keepalives_interval`, in seconds. 0 leaves the server's own.
    #[serde(default)]
    pub keepalive_interval_seconds: u32,
    /// `tcp_keepalives_count`. 0 leaves the server's own.
    #[serde(default)]
    pub keepalive_count: u32,
    /// `TimeZone` for every session. Empty leaves the server's own.
    #[serde(default)]
    pub default_time_zone: String,
}

fn default_connection_port() -> u32 { 5432 }
fn default_search_path_suffix() -> String { "public".to_string() }
fn default_max_connections() -> u32 { 5 }
fn default_connect_timeout_seconds() -> u32 { 10 }
fn default_idle_timeout_seconds() -> u32 { 600 }
fn default_max_lifetime_seconds() -> u32 { 1800 }
fn default_idle_in_transaction_seconds() -> u32 { 30 }

impl Default for ConnectionSettings {
    fn default() -> Self {
        ConnectionSettings {
            default_port: default_connection_port(),
            application_name: String::new(),
            search_path_suffix: default_search_path_suffix(),
            max_connections: default_max_connections(),
            connect_timeout_seconds: default_connect_timeout_seconds(),
            idle_timeout_seconds: default_idle_timeout_seconds(),
            max_lifetime_seconds: default_max_lifetime_seconds(),
            idle_in_transaction_seconds: default_idle_in_transaction_seconds(),
            keepalive_idle_seconds: 0,
            keepalive_interval_seconds: 0,
            keepalive_count: 0,
            default_time_zone: String::new(),
        }
    }
}

impl ConnectionSettings {
    /// The `application_name` to send, or None to send none.
    ///
    /// An empty setting means `Pharos <version>`. The version is the crate's
    /// own: `.github/workflows/release.yml` stamps `CFBundleShortVersionString`
    /// and `pharos-core/Cargo.toml` from the SAME tag, so this string is the
    /// bundle's short version string, without a second FFI call to fetch it.
    ///
    /// A name the user typed is sent trimmed. Trimmed to nothing is the same
    /// as empty.
    pub fn effective_application_name(&self) -> String {
        let typed = self.application_name.trim();
        if typed.is_empty() {
            concat!("Pharos ", env!("CARGO_PKG_VERSION")).to_string()
        } else {
            typed.to_string()
        }
    }
}

// MARK: - Export & Import

/// Settings ▸ Export & Import, the export half.
///
/// Every default is what the app did before the setting existed:
///   default_format     `Csv`  — `ExportDataSheet.swift` filled its popup from
///                               `ExportFormat.allCases` and selected none, so
///                               the first case, CSV, was the one that ran.
///   remember_last_choices `false` — the sheet remembered nothing at all.
///   dialect            default — see `models/export_import.rs`.
///   include_header_row `true`  — `includeHeadersCheckbox.state = .on`.
///   default_folder     empty   — the save panel was given no `directoryURL`.
///   batch_size         `5000`  — `let batch_size: i64 = 5000;` in
///                                `commands/table.rs::stream_export`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DataExportSettings {
    #[serde(default)]
    pub default_format: ExportFormat,
    /// Whether the export sheet's choices are written back here when the user
    /// exports, so the next export opens where the last one left off.
    #[serde(default)]
    pub remember_last_choices: bool,
    #[serde(default)]
    pub dialect: CsvDialect,
    #[serde(default = "default_true_export")]
    pub include_header_row: bool,
    /// Where the save panel opens. Empty means wherever macOS last put it.
    /// A plain path: the app is not sandboxed.
    #[serde(default)]
    pub default_folder: String,
    /// Rows fetched per round trip while streaming an export. Clamped to at
    /// least 1 by the engine, so 0 cannot wedge the loop.
    #[serde(default = "default_export_batch_size")]
    pub batch_size: u32,
}

fn default_true_export() -> bool { true }
fn default_export_batch_size() -> u32 { 5000 }

impl Default for DataExportSettings {
    fn default() -> Self {
        DataExportSettings {
            default_format: ExportFormat::default(),
            remember_last_choices: false,
            dialect: CsvDialect::default(),
            include_header_row: default_true_export(),
            default_folder: String::new(),
            batch_size: default_export_batch_size(),
        }
    }
}

/// Settings ▸ Export & Import, the import half.
///
/// `on_error` defaults to `Abort` and `commit_every` to 0 (one transaction),
/// which together are exactly what `commands/table.rs::import_csv` did before
/// either setting existed.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DataImportSettings {
    #[serde(default)]
    pub dialect: CsvDialect,
    #[serde(default)]
    pub on_error: ImportErrorPolicy,
    /// Rows per transaction. 0 is one transaction for the whole file.
    #[serde(default)]
    pub commit_every: u32,
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
    #[serde(default)]
    pub session: SessionSettings,
    /// Whether the editor and the results grid pin legacy scroll bars on
    /// screen. Defaults OFF — follow the system's scroll-bar preference, as
    /// the HIG asks — so a bare `#[serde(default)]` is the right default here.
    #[serde(default)]
    pub always_show_scroll_bars: bool,
    /// The per-feature Apple Intelligence switches, under the master above.
    #[serde(default)]
    pub intelligence: IntelligenceSettings,
    #[serde(default)]
    pub notifications: NotificationSettings,
    #[serde(default)]
    pub diagnostics: DiagnosticsSettings,
    #[serde(default)]
    pub security: SecuritySettings,
    /// The Database Navigator. `show_leaf_partitions` stays above, top-level:
    /// moving it here would rename its key on the wire.
    #[serde(default)]
    pub navigator: NavigatorSettings,
    /// The Query Library navigator, and the Save Query sheet.
    #[serde(default)]
    pub library: LibrarySettings,
    /// The Results History navigator.
    #[serde(default)]
    pub history: HistorySettings,
    /// Settings ▸ Connections: the new-connection defaults and the pool and
    /// session tuning every connect uses.
    #[serde(default)]
    pub connections: ConnectionSettings,
    /// Settings ▸ Export & Import, the export half. `data_` because `import`
    /// is a Swift keyword and the two names stay a pair.
    #[serde(default)]
    pub data_export: DataExportSettings,
    /// Settings ▸ Export & Import, the import half.
    #[serde(default)]
    pub data_import: DataImportSettings,
}

fn default_check_for_updates() -> bool { true }
fn default_vertical_result_tabs() -> bool { true }
fn default_use_apple_intelligence() -> bool { true }

// MARK: - Database Navigator

/// How the Database Navigator orders the objects inside a schema.
/// `KindThenName` is what it did before the setting existed.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ObjectSortMode {
    #[default]
    KindThenName,
    Name,
    Size,
    RowEstimate,
}

/// How the schemas themselves are ordered. `Name` is the order the server
/// returns them in, which is what the Navigator showed before this existed.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SchemaSortMode {
    #[default]
    Name,
    DefaultFirst,
}

/// What a double-click on a Navigator row does. `Expand` is today's.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum NavigatorDoubleClickAction {
    #[default]
    Expand,
    ViewContents,
    Describe,
    InsertName,
}

/// How the Partitions group orders a table's partitions. `Name` is what the
/// Navigator asked for before the setting existed.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PartitionSortMode {
    Bound,
    #[default]
    Name,
    Size,
}

/// The Database Navigator's own settings. `show_leaf_partitions` is NOT here:
/// it is a top-level field and moving it would rename its key on the wire.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct NavigatorSettings {
    #[serde(default)]
    pub schema_sort: SchemaSortMode,
    /// Whether `pg_catalog` and `information_schema` are listed at all.
    /// Off is what the Navigator has always shown. The storage schemas
    /// (`pg_toast*`, `pg_temp_*`) stay hidden whichever this says.
    #[serde(default)]
    pub show_system_schemas: bool,
    #[serde(default)]
    pub object_sort: ObjectSortMode,
    #[serde(default)]
    pub partition_sort: PartitionSortMode,
    #[serde(default = "yes")]
    pub auto_expand_default_schema: bool,
    #[serde(default = "default_auto_expand_threshold")]
    pub auto_expand_threshold: u32,
    #[serde(default)]
    pub double_click_action: NavigatorDoubleClickAction,
    #[serde(default = "yes")]
    pub view_contents_uses_row_limit: bool,
    #[serde(default = "default_limit_presets")]
    pub limit_presets: Vec<u32>,
}

fn default_auto_expand_threshold() -> u32 { 500 }
fn default_limit_presets() -> Vec<u32> { vec![10, 100, 1000, 10000] }

impl Default for NavigatorSettings {
    fn default() -> Self {
        NavigatorSettings {
            schema_sort: SchemaSortMode::default(),
            show_system_schemas: false,
            object_sort: ObjectSortMode::default(),
            partition_sort: PartitionSortMode::default(),
            auto_expand_default_schema: true,
            auto_expand_threshold: default_auto_expand_threshold(),
            double_click_action: NavigatorDoubleClickAction::default(),
            view_contents_uses_row_limit: true,
            limit_presets: default_limit_presets(),
        }
    }
}

// MARK: - Query Library and History

/// How the Query Library navigator orders what it shows. `Folder` is today's.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SavedQuerySortMode {
    #[default]
    Folder,
    Name,
    RecentlyUpdated,
}

/// What a double-click on a saved query does. `Open` is today's.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SavedQueryDoubleClickAction {
    #[default]
    Open,
    OpenAndRun,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySettings {
    /// Empty means unfiled, which is what the Save Query sheet opens on.
    #[serde(default)]
    pub default_folder: String,
    #[serde(default)]
    pub sort_mode: SavedQuerySortMode,
    #[serde(default)]
    pub double_click_action: SavedQueryDoubleClickAction,
}

/// The Results History navigator. There is no paging: the list is one fetch,
/// and 200 is the number it was hard-coded to.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistorySettings {
    #[serde(default = "default_maximum_history_entries")]
    pub maximum_entries: u32,
    /// Days of history to keep. 0 keeps it forever. 90 is the literal the
    /// store pruned by before this was a setting.
    #[serde(default = "default_history_retention_days")]
    pub retention_days: u32,
    /// Most entries to keep, newest first. 0 is no ceiling, which is what
    /// the store did before this was a setting.
    #[serde(default)]
    pub maximum_stored_entries: u32,
    /// Whether a query that FAILED leaves a row in Query History.
    ///
    /// ON, and this one default is NOT what the app did before: until this
    /// slice a failure left no trace at all. Recording it is the feature, so
    /// a user who never opens Settings gets it. Only a failure the SERVER
    /// answered is recorded — a client-side refusal ("connect to a database
    /// first") is dropped by `HistoryFailureFilter` on the Swift side, which
    /// is where the decision is made.
    #[serde(default = "default_true")]
    pub record_failed_queries: bool,
}

fn default_maximum_history_entries() -> u32 { 200 }
fn default_history_retention_days() -> u32 { 90 }

impl Default for HistorySettings {
    fn default() -> Self {
        HistorySettings {
            maximum_entries: default_maximum_history_entries(),
            retention_days: default_history_retention_days(),
            maximum_stored_entries: 0,
            record_failed_queries: true,
        }
    }
}

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
            session: SessionSettings::default(),
            always_show_scroll_bars: false,
            intelligence: IntelligenceSettings::default(),
            notifications: NotificationSettings::default(),
            diagnostics: DiagnosticsSettings::default(),
            security: SecuritySettings::default(),
            navigator: NavigatorSettings::default(),
            library: LibrarySettings::default(),
            history: HistorySettings::default(),
            connections: ConnectionSettings::default(),
            data_export: DataExportSettings::default(),
            data_import: DataImportSettings::default(),
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
    use crate::models::export_import::{CsvDelimiter, CsvEncoding, CsvQuoteStyle};
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
                    format_indent_width: 3,
                    format_uppercase_keywords: false,
                    format_lines_between_statements: 1,
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
                session: SessionSettings {
                    autosave_interval_seconds: 31,
                    restore_window_frames: false,
                    default_editor_split_ratio: 0.45,
                },
                always_show_scroll_bars: true,
                intelligence: IntelligenceSettings {
                    describe_query: false,
                    explain_errors: false,
                    suggest_saved_query_names: false,
                    name_tabs_automatically: false,
                    summarise_plans: false,
                    suggest_charts: false,
                    allow_drafting_write_statements: false,
                },
                notifications: NotificationSettings {
                    play_sound: false,
                    badge_dock_icon: false,
                    toast_duration: ToastDuration::Long,
                },
                diagnostics: DiagnosticsSettings {
                    metadata_cache_ttl_minutes: 1,
                    log_level: LogLevel::Debug,
                },
                security: SecuritySettings {
                    index_saved_queries_in_spotlight: false,
                    collect_performance_metrics: false,
                },
                navigator: NavigatorSettings {
                    schema_sort: SchemaSortMode::DefaultFirst,
                    show_system_schemas: true,
                    object_sort: ObjectSortMode::Size,
                    partition_sort: PartitionSortMode::Bound,
                    auto_expand_default_schema: false,
                    auto_expand_threshold: 501,
                    double_click_action: NavigatorDoubleClickAction::ViewContents,
                    view_contents_uses_row_limit: false,
                    limit_presets: vec![5, 50],
                },
                library: LibrarySettings {
                    default_folder: "Reports".to_string(),
                    sort_mode: SavedQuerySortMode::RecentlyUpdated,
                    double_click_action: SavedQueryDoubleClickAction::OpenAndRun,
                },
                history: HistorySettings {
                    maximum_entries: 201,
                    retention_days: 91,
                    maximum_stored_entries: 1,
                    record_failed_queries: false,
                },
                connections: ConnectionSettings {
                    default_port: 5433,
                    application_name: "Pharos (staging)".to_string(),
                    search_path_suffix: "public, extensions".to_string(),
                    max_connections: 6,
                    connect_timeout_seconds: 11,
                    idle_timeout_seconds: 601,
                    max_lifetime_seconds: 1801,
                    idle_in_transaction_seconds: 31,
                    keepalive_idle_seconds: 60,
                    keepalive_interval_seconds: 10,
                    keepalive_count: 6,
                    default_time_zone: "Asia/Tokyo".to_string(),
                },
                data_export: DataExportSettings {
                    default_format: ExportFormat::Tsv,
                    remember_last_choices: true,
                    dialect: CsvDialect {
                        delimiter: CsvDelimiter::Semicolon,
                        custom_delimiter: "~".to_string(),
                        quote_char: "'".to_string(),
                        quote_style: CsvQuoteStyle::Always,
                        null_literal: "\\N".to_string(),
                        encoding: CsvEncoding::Utf8Bom,
                    },
                    include_header_row: false,
                    default_folder: "/tmp/exports".to_string(),
                    batch_size: 5001,
                },
                data_import: DataImportSettings {
                    dialect: CsvDialect {
                        delimiter: CsvDelimiter::Pipe,
                        custom_delimiter: "^".to_string(),
                        quote_char: "`".to_string(),
                        quote_style: CsvQuoteStyle::Never,
                        null_literal: "(null)".to_string(),
                        encoding: CsvEncoding::Latin1,
                    },
                    on_error: ImportErrorPolicy::SkipRow,
                    commit_every: 500,
                },
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
