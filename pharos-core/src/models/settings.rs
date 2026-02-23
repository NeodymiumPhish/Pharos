use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSettings {
    pub font_size: u32,
    pub font_family: String,
    pub tab_size: u32,
    pub word_wrap: bool,
    pub minimap: bool,
    pub line_numbers: bool,
}

impl Default for EditorSettings {
    fn default() -> Self {
        EditorSettings {
            font_size: 13,
            font_family: "JetBrains Mono, Monaco, Menlo, monospace".to_string(),
            tab_size: 2,
            word_wrap: false,
            minimap: false,
            line_numbers: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySettings {
    pub default_limit: u32,
    pub timeout_seconds: u32,
    pub auto_commit: bool,
    pub confirm_destructive: bool,
}

impl Default for QuerySettings {
    fn default() -> Self {
        QuerySettings {
            default_limit: 1000,
            timeout_seconds: 30,
            auto_commit: true,
            confirm_destructive: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UISettings {
    pub navigator_width: u32,
    pub saved_queries_width: u32,
    pub results_panel_height: u32,
    #[serde(default = "default_editor_split_position")]
    pub editor_split_position: u32,
}

fn default_editor_split_position() -> u32 {
    40
}

impl Default for UISettings {
    fn default() -> Self {
        UISettings {
            navigator_width: 260,
            saved_queries_width: 180,
            results_panel_height: 300,
            editor_split_position: 40,
        }
    }
}

/// Keyboard shortcut configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct KeyboardShortcut {
    pub id: String,
    pub label: String,
    pub description: String,
    pub key: String,
    pub modifiers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct KeyboardSettings {
    #[serde(default)]
    pub shortcuts: HashMap<String, KeyboardShortcut>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub theme: ThemeMode,
    pub editor: EditorSettings,
    pub query: QuerySettings,
    pub ui: UISettings,
    #[serde(default)]
    pub keyboard: KeyboardSettings,
    #[serde(default)]
    pub empty_folders: Vec<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            theme: ThemeMode::default(),
            editor: EditorSettings::default(),
            query: QuerySettings::default(),
            ui: UISettings::default(),
            keyboard: KeyboardSettings::default(),
            empty_folders: Vec::new(),
        }
    }
}
