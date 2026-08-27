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

#[derive(Debug, Clone, Serialize, Deserialize)]
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
    #[serde(default)]
    pub minimap: bool,
    #[serde(default = "default_line_numbers")]
    pub line_numbers: bool,
}

fn default_font_size() -> u32 { 13 }
fn default_font_family() -> String { "JetBrains Mono, Monaco, Menlo, monospace".to_string() }
fn default_tab_size() -> u32 { 2 }
fn default_line_numbers() -> bool { true }

impl Default for EditorSettings {
    fn default() -> Self {
        EditorSettings {
            font_size: default_font_size(),
            font_family: default_font_family(),
            tab_size: default_tab_size(),
            word_wrap: false,
            minimap: false,
            line_numbers: default_line_numbers(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySettings {
    #[serde(default = "default_default_limit")]
    pub default_limit: u32,
    #[serde(default = "default_timeout_seconds")]
    pub timeout_seconds: u32,
    // Kept only so stored settings JSON round-trips; no UI and no effect —
    // queries run in PostgreSQL's implicit auto-commit mode.
    #[serde(default = "default_auto_commit")]
    pub auto_commit: bool,
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
}

fn default_default_limit() -> u32 { 1000 }
fn default_timeout_seconds() -> u32 { 300 }
fn default_auto_commit() -> bool { true }
fn default_confirm_destructive() -> bool { true }
fn default_notify_when_app_inactive() -> bool { true }
fn default_notify_when_background_tab() -> bool { true }
fn default_notify_min_duration_seconds() -> u32 { 5 }
fn default_show_cancelled_query_dialog() -> bool { true }

impl Default for QuerySettings {
    fn default() -> Self {
        QuerySettings {
            default_limit: default_default_limit(),
            timeout_seconds: default_timeout_seconds(),
            auto_commit: default_auto_commit(),
            confirm_destructive: default_confirm_destructive(),
            notify_when_app_inactive: default_notify_when_app_inactive(),
            notify_when_background_tab: default_notify_when_background_tab(),
            notify_min_duration_seconds: default_notify_min_duration_seconds(),
            show_cancelled_query_dialog: default_show_cancelled_query_dialog(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UISettings {
    #[serde(default = "default_navigator_width")]
    pub navigator_width: u32,
    #[serde(default = "default_saved_queries_width")]
    pub saved_queries_width: u32,
    #[serde(default = "default_results_panel_height")]
    pub results_panel_height: u32,
    #[serde(default = "default_editor_split_position")]
    pub editor_split_position: u32,
}

// A bare #[serde(default)] on these would give 0 — a zero-width navigator is
// worse than the missing key it replaces, so each needs the real default.
fn default_navigator_width() -> u32 { 260 }
fn default_saved_queries_width() -> u32 { 180 }
fn default_results_panel_height() -> u32 { 300 }
fn default_editor_split_position() -> u32 { 40 }

impl Default for UISettings {
    fn default() -> Self {
        UISettings {
            navigator_width: default_navigator_width(),
            saved_queries_width: default_saved_queries_width(),
            results_panel_height: default_results_panel_height(),
            editor_split_position: default_editor_split_position(),
        }
    }
}

/// Keyboard shortcut configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct KeyboardShortcut {
    // Every field is a string or a list, so the zero value — empty — is the
    // right default. One malformed entry must not sink the whole blob.
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub modifiers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct KeyboardSettings {
    #[serde(default)]
    pub shortcuts: Vec<KeyboardShortcut>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(default)]
    pub theme: ThemeMode,
    #[serde(default)]
    pub editor: EditorSettings,
    #[serde(default)]
    pub query: QuerySettings,
    #[serde(default)]
    pub ui: UISettings,
    #[serde(default)]
    pub keyboard: KeyboardSettings,
    #[serde(default)]
    pub empty_folders: Vec<String>,
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
    #[serde(default)]
    pub charts: ChartSettings,
}

fn default_check_for_updates() -> bool { true }
fn default_vertical_result_tabs() -> bool { true }

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            theme: ThemeMode::default(),
            editor: EditorSettings::default(),
            query: QuerySettings::default(),
            ui: UISettings::default(),
            keyboard: KeyboardSettings::default(),
            empty_folders: Vec::new(),
            null_display: NullDisplay::default(),
            bool_display: BoolDisplay::default(),
            check_for_updates: default_check_for_updates(),
            show_leaf_partitions: false,
            vertical_result_tabs: default_vertical_result_tabs(),
            charts: ChartSettings::default(),
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
            "autoCommit": true,
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
            "editor": {"fontFamily": "Menlo", "fontSize": 13, "tabSize": 2, "lineNumbers": true, "wordWrap": false, "minimap": false},
            "query": {"defaultLimit": 500, "timeoutSeconds": 30, "autoCommit": true, "confirmDestructive": true},
            "ui": {"navigatorWidth": 260, "savedQueriesWidth": 180, "resultsPanelHeight": 300}
        }"#;
        let parsed: AppSettings = serde_json::from_str(json).expect("old settings must still parse");
        // Two separate code paths, each hand-written and each able to regress
        // alone: the serde attribute, then the Default impl.
        assert!(parsed.vertical_result_tabs, "the serde default gives true");
        assert!(AppSettings::default().vertical_result_tabs, "the Default impl also gives true");
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
        assert_eq!(parsed.minimap, d.minimap);
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
        assert_eq!(parsed.auto_commit, d.auto_commit);
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
    fn ui_settings_parse_from_empty_object() {
        let parsed: UISettings = serde_json::from_str("{}").expect("an empty object must parse");
        let d = UISettings::default();
        assert_eq!(parsed.navigator_width, d.navigator_width);
        assert_eq!(parsed.saved_queries_width, d.saved_queries_width);
        assert_eq!(parsed.results_panel_height, d.results_panel_height);
        assert_eq!(parsed.editor_split_position, d.editor_split_position);
        // Each pane must come back at its real width. A bare
        // #[serde(default)] would give 0 and collapse the pane.
        assert_eq!(parsed.navigator_width, 260);
        assert_eq!(parsed.saved_queries_width, 180);
        assert_eq!(parsed.results_panel_height, 300);
        assert_eq!(parsed.editor_split_position, 40);
    }

    #[test]
    fn keyboard_settings_parse_from_empty_object() {
        let parsed: KeyboardSettings = serde_json::from_str("{}").expect("an empty object must parse");
        assert!(parsed.shortcuts.is_empty(), "no stored shortcuts gives an empty list");
    }

    #[test]
    fn keyboard_shortcut_parse_from_partial_object() {
        // A shortcut entry written by an older build can miss a key. That
        // entry must come back empty, not sink the whole settings blob.
        let json = r#"{"id": "run-query", "key": "Return"}"#;
        let parsed: KeyboardShortcut = serde_json::from_str(json).expect("a partial entry must still parse");
        assert_eq!(parsed.id, "run-query");
        assert_eq!(parsed.key, "Return");
        assert_eq!(parsed.label, "");
        assert_eq!(parsed.description, "");
        assert!(parsed.modifiers.is_empty());
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
        assert!(parsed.empty_folders.is_empty());
        // The four nested structs must also come back at their defaults.
        assert_eq!(parsed.editor.font_size, d.editor.font_size);
        assert_eq!(parsed.query.default_limit, d.query.default_limit);
        assert_eq!(parsed.ui.navigator_width, d.ui.navigator_width);
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
            "query": {"defaultLimit": 42},
            "ui": {"navigatorWidth": 400}
        }"#;
        let parsed: AppSettings = serde_json::from_str(json).expect("old settings must still parse");
        // Stored values survive.
        assert_eq!(parsed.theme, ThemeMode::Dark);
        assert_eq!(parsed.editor.font_size, 18);
        assert_eq!(parsed.editor.font_family, "Menlo");
        assert_eq!(parsed.query.default_limit, 42);
        assert_eq!(parsed.ui.navigator_width, 400);
        // Absent keys fall back, each on its own.
        assert_eq!(parsed.editor.tab_size, 2);
        assert!(parsed.editor.line_numbers);
        assert_eq!(parsed.query.timeout_seconds, 300);
        assert!(parsed.query.confirm_destructive);
        assert_eq!(parsed.ui.saved_queries_width, 180);
        assert_eq!(parsed.ui.results_panel_height, 300);
    }
}
