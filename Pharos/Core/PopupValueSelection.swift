import AppKit

/// Reads the real value out of a popup whose titles are escaped for display.
///
/// Once a menu title is escaped, it is no longer the value — reading
/// `titleOfSelectedItem` back would persist `"public<U+200B>"` as a schema
/// name. Each item carries its raw value in `representedObject` and this is
/// the only way that value is read.
///
/// Deliberately returns nil rather than falling back to the title when an item
/// has no `representedObject`: a fallback is exactly how the escaped string
/// would reach the store, and a sentinel row ("None", "New Folder...") has no
/// value by design. Callers distinguish "no selection" from "sentinel" by
/// their own means, as they already do.
enum PopupValueSelection {

    static func selectedValue(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }
}
