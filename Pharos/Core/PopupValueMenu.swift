import AppKit

/// Builds and reads a popup whose titles are escaped for display and whose real
/// values ride along in `representedObject`.
///
/// Once a menu title is escaped it is no longer the value — reading
/// `titleOfSelectedItem` back would persist `"public<U+200B>"` as a schema
/// name. So the raw value travels on the item, and population, selection and
/// read-back all live here together: they share one invariant — row *i* holds
/// value *i* — and splitting them across call sites is what let that invariant
/// break silently.
enum PopupValueMenu {

    /// Populates `popup` with an optional sentinel row (no value) followed by
    /// one row per value: escaped title for the eye, raw value in
    /// `representedObject`.
    ///
    /// Uses `NSMenuItem` + `menu.addItem(_:)`, NEVER
    /// `NSPopUpButton.addItem(withTitle:)`, because that method DELETES an
    /// existing item with the same title. Once titles are escaped two distinct
    /// values can produce one title, and a value can collide with the sentinel
    /// — either way a row silently disappears, the row count stops matching
    /// the value count, and index arithmetic reads back somebody else's value.
    ///
    /// Measured, before this existed: with schemas `["None", "public",
    /// "sales"]` under a `"None"` sentinel, AppKit deleted the sentinel and
    /// `selectItem(at: idx + 1)` went off by one — a saved default of `None`
    /// displayed and stored `public`. `CREATE SCHEMA "None"` is legal, and the
    /// wrong name round-trips with no symptom, which is worse than the
    /// visibly-corrupt escaped string this whole mechanism replaced.
    static func populate(_ popup: NSPopUpButton, sentinel: String?, values: [String]) {
        popup.removeAllItems()
        guard let menu = popup.menu else { return }
        if let sentinel {
            let item = NSMenuItem(title: sentinel, action: nil, keyEquivalent: "")
            item.representedObject = nil
            menu.addItem(item)
        }
        for value in values {
            let item = NSMenuItem(title: DisplayEscape.escaped(value), action: nil, keyEquivalent: "")
            item.representedObject = value
            menu.addItem(item)
        }
    }

    /// Selects the row whose raw value equals `value`, by VALUE not by index —
    /// so no caller has to keep popup positions and array positions in step.
    /// Leaves the selection alone when there is no such row.
    static func selectValue(_ value: String?, in popup: NSPopUpButton) {
        guard let value,
              let index = popup.itemArray.firstIndex(where: {
                  $0.representedObject as? String == value
              }) else { return }
        popup.selectItem(at: index)
    }

    /// Deliberately returns nil rather than falling back to the title when an
    /// item has no `representedObject`: a fallback is exactly how the escaped
    /// string would reach the store, and a sentinel row ("None", "New
    /// Folder...") has no value by design. Callers distinguish "no selection"
    /// from "sentinel" by their own means, as they already do.
    static func selectedValue(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }
}
