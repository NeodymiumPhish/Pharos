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
        }
    }
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
    /// Whether the on-device Apple Intelligence features are offered at all.
    /// Defaults ON: the model runs on this Mac and sends nothing anywhere, and
    /// a user who does not want it turns it off in Settings ▸ General.
    #[serde(default = "default_use_apple_intelligence")]
    pub use_apple_intelligence: bool,
    #[serde(default)]
    pub charts: ChartSettings,
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
            empty_folders: Vec::new(),
            null_display: NullDisplay::default(),
            bool_display: BoolDisplay::default(),
            check_for_updates: default_check_for_updates(),
            show_leaf_partitions: false,
            vertical_result_tabs: default_vertical_result_tabs(),
            use_apple_intelligence: default_use_apple_intelligence(),
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
        assert!(parsed.empty_folders.is_empty());
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
    /// `editor.minimap` and `query.autoCommit` must still parse after those
    /// fields were removed (serde ignores unknown keys by default), the live
    /// keys in the same blob must survive, and re-serializing must not bring
    /// the removed keys back.
    #[test]
    fn app_settings_ignores_removed_keys_from_older_builds() {
        let json = r#"{
            "theme": "dark",
            "editor": {"fontSize": 18, "fontFamily": "Menlo", "minimap": true},
            "query": {"defaultLimit": 42, "autoCommit": false},
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
    }
}
