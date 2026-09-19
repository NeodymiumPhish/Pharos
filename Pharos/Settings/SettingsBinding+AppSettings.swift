import Foundation

// The bindings that reach the real store. Kept out of `Furniture/` because
// they touch `AppStateManager`, which the standalone harness does not compile.

extension SettingsBinding {

    /// One field of `AppSettings`. `get` reads the published settings as they
    /// stand NOW; `set` mutates that current value and saves — never a
    /// snapshot taken when the pane was built, so two panes cannot overwrite
    /// each other's fields.
    @MainActor
    static func settings(_ keyPath: WritableKeyPath<AppSettings, Value>) -> SettingsBinding {
        SettingsBinding(
            get: { AppStateManager.shared.settings[keyPath: keyPath] },
            set: { value in
                let manager = AppStateManager.shared
                let current = manager.settings
                var updated = current
                updated[keyPath: keyPath] = value
                guard updated != current else { return }
                manager.saveSettings(updated)
            })
    }
}

extension SettingsBinding where Value == Int {
    /// A `UInt32` field seen as the `Int` a stepper works in.
    @MainActor
    static func settings(_ keyPath: WritableKeyPath<AppSettings, UInt32>) -> SettingsBinding<Int> {
        SettingsBinding<UInt32>.settings(keyPath).map(to: { Int($0) }, from: { UInt32(max(0, $0)) })
    }
}

extension SettingsChoice {

    /// A `String`-backed `CaseIterable` enum field.
    @MainActor
    static func cases<E: CaseIterable & RawRepresentable & Equatable>(
        _ keyPath: WritableKeyPath<AppSettings, E>, title: @escaping (E) -> String
    ) -> SettingsChoice where E.RawValue == String {
        cases(SettingsBinding<E>.settings(keyPath), title: title)
    }

    /// A field with a short list of allowed values.
    @MainActor
    static func values<V: Equatable>(
        _ keyPath: WritableKeyPath<AppSettings, V>, options: [(title: String, value: V)]
    ) -> SettingsChoice {
        values(SettingsBinding<V>.settings(keyPath), options: options)
    }
}
