use tauri::{Emitter, Manager};
use tauri::menu::{Menu, MenuItem, Submenu};

#[cfg(target_os = "macos")]
use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial};

mod commands;
mod db;
mod models;
mod state;

use state::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .menu(|app| {
            // Create a minimal menu that doesn't conflict with our app shortcuts
            let app_menu = Submenu::with_items(
                app,
                "Pharos",
                true,
                &[
                    &MenuItem::with_id(app, "about", "About Pharos", true, None::<&str>)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &MenuItem::with_id(
                        app,
                        "settings",
                        "Settings...",
                        true,
                        Some("CmdOrCtrl+,"),
                    )?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::services(app, None)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::hide(app, None)?,
                    &tauri::menu::PredefinedMenuItem::hide_others(app, None)?,
                    &tauri::menu::PredefinedMenuItem::show_all(app, None)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::quit(app, None)?,
                ],
            )?;

            let edit_menu = Submenu::with_items(
                app,
                "Edit",
                true,
                &[
                    &tauri::menu::PredefinedMenuItem::undo(app, None)?,
                    &tauri::menu::PredefinedMenuItem::redo(app, None)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::cut(app, None)?,
                    &tauri::menu::PredefinedMenuItem::copy(app, None)?,
                    &tauri::menu::PredefinedMenuItem::paste(app, None)?,
                    &tauri::menu::PredefinedMenuItem::select_all(app, None)?,
                ],
            )?;

            let window_menu = Submenu::with_items(
                app,
                "Window",
                true,
                &[
                    &tauri::menu::PredefinedMenuItem::minimize(app, None)?,
                    &tauri::menu::PredefinedMenuItem::maximize(app, None)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::fullscreen(app, None)?,
                ],
            )?;

            Menu::with_items(app, &[&app_menu, &edit_menu, &window_menu])
        })
        .on_menu_event(|app, event| {
            match event.id().as_ref() {
                "about" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.emit("menu-about", ());
                    }
                }
                "settings" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.emit("menu-settings", ());
                    }
                }
                _ => {}
            }
        })
        .setup(|app| {
            // Setup logging in debug mode
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // Apply vibrancy effect on macOS
            #[cfg(target_os = "macos")]
            {
                let window = app.get_webview_window("main").unwrap();
                apply_vibrancy(&window, NSVisualEffectMaterial::UnderWindowBackground, None, None)
                    .expect("Failed to apply vibrancy");
            }

            // Initialize the application state
            let app_data_dir = app
                .path()
                .app_data_dir()
                .expect("Failed to get app data directory");

            let metadata_db = db::sqlite::init_database(&app_data_dir)
                .expect("Failed to initialize SQLite database");

            let app_state = AppState::new(metadata_db);

            // Load saved connections into memory
            {
                let db = app_state.metadata_db.lock().unwrap();
                if let Ok(configs) = db::sqlite::load_connections(&db) {
                    for config in configs {
                        app_state.set_config(config);
                    }
                }
            }

            app.manage(app_state);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Connection commands
            commands::save_connection,
            commands::delete_connection,
            commands::load_connections,
            commands::connect_postgres,
            commands::disconnect_postgres,
            commands::test_connection,
            commands::get_connection_status,
            // Metadata commands
            commands::get_schemas,
            commands::get_tables,
            commands::get_columns,
            // Query commands
            commands::execute_query,
            commands::execute_statement,
            commands::cancel_query,
            commands::validate_sql,
            // Saved query commands
            commands::create_saved_query,
            commands::load_saved_queries,
            commands::get_saved_query,
            commands::update_saved_query,
            commands::delete_saved_query,
            // Settings commands
            commands::load_settings,
            commands::save_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
