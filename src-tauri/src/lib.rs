use tauri::{Emitter, Manager};
use tauri::menu::{Menu, MenuItem, Submenu};

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
            #[cfg(target_os = "macos")]
            {
                use tauri_plugin_vibrancy::MacOSVibrancy;
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.apply_vibrancy(
                        tauri_plugin_vibrancy::NSVisualEffectMaterial::Sidebar,
                        None,
                        None,
                    );
                }
            }

            // Setup logging in debug mode
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // Initialize the application state
            let app_data_dir = app
                .path()
                .app_data_dir()
                .expect("Failed to get app data directory");

            let metadata_db = db::sqlite::init_database(&app_data_dir)
                .expect("Failed to initialize SQLite database");

            let app_state = AppState::new(metadata_db);

            // Load saved connections into memory and initialize password cache
            {
                let db = app_state.metadata_db.lock().unwrap();
                if let Ok(configs) = db::sqlite::load_connections(&db) {
                    // Collect connection IDs for password migration
                    let connection_ids: Vec<String> = configs.iter().map(|c| c.id.clone()).collect();

                    // Migrate any legacy per-connection keychain entries to the unified format
                    // and load all passwords into the in-memory cache.
                    // This is the ONLY keychain access during startup - all subsequent
                    // password lookups use the in-memory cache.
                    match db::credentials::migrate_legacy_passwords(&connection_ids) {
                        Ok(passwords) => {
                            app_state.init_password_cache(passwords);
                        }
                        Err(e) => {
                            log::warn!("Failed to load passwords from keychain: {}", e);
                        }
                    }

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
            commands::reorder_connections,
            // Metadata commands
            commands::get_schemas,
            commands::get_tables,
            commands::get_columns,
            commands::analyze_schema,
            commands::get_table_indexes,
            commands::get_table_constraints,
            commands::get_schema_functions,
            commands::generate_table_ddl,
            commands::generate_index_ddl,
            // Query commands
            commands::execute_query,
            commands::execute_statement,
            commands::fetch_more_rows,
            commands::cancel_query,
            commands::validate_sql,
            commands::check_query_editable,
            commands::commit_data_edits,
            // Saved query commands
            commands::create_saved_query,
            commands::load_saved_queries,
            commands::get_saved_query,
            commands::update_saved_query,
            commands::delete_saved_query,
            // Settings commands
            commands::load_settings,
            commands::save_settings,
            // Table commands
            commands::clone_table,
            commands::validate_csv_for_import,
            commands::import_csv,
            commands::export_table,
            commands::export_results,
            commands::export_query,
            commands::write_text_export,
            // Query history commands
            commands::load_query_history,
            commands::delete_query_history_entry,
            commands::clear_query_history,
            commands::get_query_history_result,
            commands::update_query_history_results,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
