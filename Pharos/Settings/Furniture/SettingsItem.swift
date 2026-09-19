import AppKit

// The declarative description of a Settings pane: sections of items, each
// item a title, a caption and one control bound to one value. AppKit only —
// no FFI, no `AppStateManager` — so `scripts/test-settings-form-builder.sh`
// compiles it standalone. `SettingsBinding+AppSettings.swift` adds the
// bindings that reach the real settings store.

/// One value the form reads and writes. `get` is called on every refresh, so
/// it must be cheap and must read the CURRENT value (not a snapshot taken
/// when the pane was built).
struct SettingsBinding<Value: Equatable> {
    let get: () -> Value
    let set: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    /// A value that lives in `UserDefaults` (the few window-memory items
    /// that are not preferences).
    static func defaults(_ key: String, default fallback: Value, in defaults: UserDefaults = .standard) -> SettingsBinding {
        SettingsBinding(
            get: { (defaults.object(forKey: key) as? Value) ?? fallback },
            set: { defaults.set($0, forKey: key) })
    }

    /// A read-only value, for rows that only display.
    static func constant(_ value: Value) -> SettingsBinding {
        SettingsBinding(get: { value }, set: { _ in })
    }

    /// View this binding as another type — a `UInt32` field as the `Int` a
    /// stepper wants, an enum as the `String` a popup wants.
    func map<Other: Equatable>(to: @escaping (Value) -> Other, from: @escaping (Other) -> Value) -> SettingsBinding<Other> {
        SettingsBinding<Other>(get: { to(get()) }, set: { set(from($0)) })
    }
}

/// A closed list of options for a popup or a segmented control. Values are
/// strings so one control type serves enums, number lists and free choices;
/// the binding does the conversion.
struct SettingsChoice {
    struct Option {
        let title: String
        let value: String
    }

    let options: [Option]
    let binding: SettingsBinding<String>

    init(options: [(title: String, value: String)], binding: SettingsBinding<String>) {
        self.options = options.map { Option(title: $0.title, value: $0.value) }
        self.binding = binding
    }

    /// A `String`-backed `CaseIterable` enum bound directly.
    static func cases<E: CaseIterable & RawRepresentable & Equatable>(
        _ binding: SettingsBinding<E>, title: @escaping (E) -> String
    ) -> SettingsChoice where E.RawValue == String {
        let all = Array(E.allCases)
        return SettingsChoice(
            options: all.map { (title: title($0), value: $0.rawValue) },
            binding: binding.map(to: { $0.rawValue }, from: { E(rawValue: $0) ?? all[0] }))
    }

    /// A list of concrete values (2 / 4 / 8 spaces, 10 / 30 / 60 seconds…).
    /// A stored value not in the list shows as the first option and is left
    /// unchanged until the user picks something.
    static func values<V: Equatable>(_ binding: SettingsBinding<V>, options: [(title: String, value: V)]) -> SettingsChoice {
        let keys = options.indices.map { String($0) }
        return SettingsChoice(
            options: zip(options, keys).map { (title: $0.0.title, value: $0.1) },
            binding: binding.map(
                to: { value in options.firstIndex { $0.value == value }.map { String($0) } ?? keys[0] },
                from: { key in options[Int(key) ?? 0].value }))
    }
}

/// Whether a row can be used on this Mac right now. Evaluated on every
/// refresh, so a feature that comes and goes (Apple Intelligence) follows.
enum SettingsAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// The control kinds a row can carry.
enum SettingsItemKind {
    /// Trailing `NSSwitch`.
    case toggle(SettingsBinding<Bool>)
    /// Trailing `NSPopUpButton`.
    case popup(SettingsChoice)
    /// Trailing `NSSegmentedControl`.
    case segmented(SettingsChoice)
    /// Number field + stepper, range-checked on commit.
    case stepper(SettingsBinding<Int>, range: ClosedRange<Int>, unit: String?)
    /// Free text, committed after a typing pause and when editing ends.
    case text(SettingsBinding<String>, width: CGFloat)
    /// Slider, written continuously.
    case slider(SettingsBinding<Double>, range: ClosedRange<Double>)
    /// A path label with a Choose… button (`NSOpenPanel`).
    case path(SettingsBinding<String>, directories: Bool)
    /// A button in the trailing slot.
    case action(title: String, destructive: Bool, handler: () -> Void)
    /// Any view, placed BELOW the text column at full width.
    case custom(() -> NSView)
    /// The "No Items" placeholder row.
    case empty(String)
}

/// One row of a section.
struct SettingsItem {
    /// Unique within the pane. Also the tail of the control's accessibility
    /// identifier: `settings.<pane>.<id>`.
    let id: String
    let title: String
    let caption: String?
    /// A caption that is recomputed on every refresh — a "Last checked: …"
    /// line, a count of stored items. It replaces `caption` when present.
    /// A static `caption` cannot do this: the builder writes it back on
    /// every refresh, so a value captured when the pane was built would be
    /// restored over anything set later.
    let dynamicCaption: (() -> String)?
    /// SF Symbol name for the leading badge, or nil for a plain row.
    let icon: String?
    /// Longer help behind an ⓘ button.
    let help: String?
    let kind: SettingsItemKind
    /// Re-evaluated on every refresh. Unavailable → the row is disabled and
    /// the reason replaces the caption.
    let availability: () -> SettingsAvailability
    /// The id of a `toggle` item in the same pane. This row is indented and
    /// enabled only while that toggle is on.
    let dependsOn: String?

    init(id: String, title: String, caption: String? = nil, dynamicCaption: (() -> String)? = nil,
         icon: String? = nil, help: String? = nil,
         kind: SettingsItemKind, availability: @escaping () -> SettingsAvailability = { .available },
         dependsOn: String? = nil) {
        self.id = id
        self.title = title
        self.caption = caption
        self.dynamicCaption = dynamicCaption
        self.icon = icon
        self.help = help
        self.kind = kind
        self.availability = availability
        self.dependsOn = dependsOn
    }
}

/// A button under a section's box, trailing-aligned.
struct SettingsFooterButton {
    let id: String
    let title: String
    let destructive: Bool
    let handler: () -> Void

    init(id: String, title: String, destructive: Bool = false, handler: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.destructive = destructive
        self.handler = handler
    }
}

/// One bold header and one grouped box of rows.
struct SettingsSection {
    let title: String?
    let items: [SettingsItem]
    let footerButtons: [SettingsFooterButton]

    init(title: String?, items: [SettingsItem], footerButtons: [SettingsFooterButton] = []) {
        self.title = title
        self.items = items
        self.footerButtons = footerButtons
    }
}
