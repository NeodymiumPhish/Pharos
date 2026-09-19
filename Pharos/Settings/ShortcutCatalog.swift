import AppKit

/// Every keyboard shortcut Pharos answers, gathered for the read-only
/// Shortcuts pane.
///
/// The menu part is read from the live `NSMenu` at run time rather than from
/// a hand-written list: a list would go stale the first time a menu item
/// changed, and nothing would fail. The keys that belong to a view and never
/// appear in a menu — Escape in the completion list, Return in the grid —
/// cannot be read from anywhere, so they are declared here beside the walk
/// and are the only hand-maintained part.
///
/// Pure enough to test: `scripts/test-shortcut-catalog.sh` builds menus by
/// hand and checks what comes out.
enum ShortcutCatalog {

    struct Entry: Equatable {
        /// The menu title, or the name of the key's job in its view.
        let command: String
        /// The menu it lives in ("File"), or the view ("Results grid").
        let group: String
        /// The shortcut as a user reads it: "⌘⇧K", "↩", "Esc".
        let shortcut: String

        /// Everything a search field can match on.
        var searchText: String { "\(command) \(group) \(shortcut)" }
    }

    // MARK: - Menus

    /// Walk a menu bar and return one entry per item that HAS a shortcut.
    /// Submenus are followed and their group is the top-level menu's title,
    /// because that is how a user names it ("it is in the View menu").
    static func entries(fromMenuBar menuBar: NSMenu) -> [Entry] {
        var result: [Entry] = []
        for top in menuBar.items {
            guard let submenu = top.submenu else { continue }
            collect(submenu, group: groupName(top: top, submenu: submenu), into: &result)
        }
        return result
    }

    /// What a user calls a top-level menu.
    ///
    /// Not `top.title`: a menu bar built in code leaves the top-level item's
    /// title EMPTY and puts the name on the submenu (`NSMenuItem()` then
    /// `NSMenu(title: "File")`), which is how `MainMenu` builds every one of
    /// them. The application menu has neither, and macOS shows the app's name
    /// there, so that is the last fallback.
    static func groupName(top: NSMenuItem, submenu: NSMenu) -> String {
        if !submenu.title.isEmpty { return submenu.title }
        if !top.title.isEmpty { return top.title }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    private static func collect(_ menu: NSMenu, group: String, into result: inout [Entry]) {
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if let shortcut = display(for: item) {
                result.append(Entry(command: item.title, group: group, shortcut: shortcut))
            }
            if let submenu = item.submenu {
                collect(submenu, group: group, into: &result)
            }
        }
    }

    /// The shortcut of one menu item, or nil when it has none.
    static func display(for item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        return display(key: key, modifiers: item.keyEquivalentModifierMask)
    }

    /// Render a key equivalent the way macOS writes it: modifiers in the
    /// Apple order, then the key.
    ///
    /// An upper-case letter in a key equivalent IS the Shift modifier —
    /// AppKit stores ⌘⇧T as key "T" with only `.command` set — so the glyph
    /// is added for it, and the key itself is shown upper case either way.
    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        let shifted = modifiers.contains(.shift) || (key.count == 1 && key.first!.isUppercase && key.first!.isLetter)
        if shifted { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + keyName(key)
    }

    /// The printable name of one key.
    static func keyName(_ key: String) -> String {
        switch key {
        case "\r", "\n": return "↩"
        case "\t": return "⇥"
        case "\u{19}": return "⇤"
        case " ": return "Space"
        case "\u{1b}": return "Esc"
        case "\u{7f}", "\u{8}": return "⌫"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        case String(UnicodeScalar(NSHomeFunctionKey)!): return "↖"
        case String(UnicodeScalar(NSEndFunctionKey)!): return "↘"
        case String(UnicodeScalar(NSPageUpFunctionKey)!): return "⇞"
        case String(UnicodeScalar(NSPageDownFunctionKey)!): return "⇟"
        case String(UnicodeScalar(NSDeleteFunctionKey)!): return "⌦"
        default: return key.uppercased()
        }
    }

    // MARK: - Keys that belong to a view

    /// The keys no menu carries. Hand-maintained, and the reason is on the
    /// type: nothing in AppKit can be asked for them.
    static let viewShortcuts: [Entry] = [
        // SQL editor — completion list
        Entry(command: String(localized: "Accept the completion"), group: String(localized: "Completion list"), shortcut: "↩"),
        Entry(command: String(localized: "Accept the completion"), group: String(localized: "Completion list"), shortcut: "⇥"),
        Entry(command: String(localized: "Next suggestion"), group: String(localized: "Completion list"), shortcut: "↓"),
        Entry(command: String(localized: "Previous suggestion"), group: String(localized: "Completion list"), shortcut: "↑"),
        Entry(command: String(localized: "Close the completion list"), group: String(localized: "Completion list"), shortcut: "Esc"),
        // SQL editor
        Entry(command: String(localized: "Indent the selected lines"), group: String(localized: "SQL editor"), shortcut: "⇥"),
        Entry(command: String(localized: "Outdent the selected lines"), group: String(localized: "SQL editor"), shortcut: "⇧⇥"),
        // Results grid
        Entry(command: String(localized: "Edit the selected cell"), group: String(localized: "Results grid"), shortcut: "↩"),
        Entry(command: String(localized: "Cancel the edit"), group: String(localized: "Results grid"), shortcut: "Esc"),
        Entry(command: String(localized: "Move down a row"), group: String(localized: "Results grid"), shortcut: "↓"),
        Entry(command: String(localized: "Move up a row"), group: String(localized: "Results grid"), shortcut: "↑"),
        Entry(command: String(localized: "Quick Look the selected cell"), group: String(localized: "Results grid"), shortcut: "Space"),
    ]

    // MARK: - The whole catalogue

    /// Every entry, menus first, each group's own order kept.
    static func all(menuBar: NSMenu?) -> [Entry] {
        let fromMenus = menuBar.map(entries(fromMenuBar:)) ?? []
        return fromMenus + viewShortcuts
    }

    /// The entries a search field's text selects. An empty or blank query
    /// selects everything. Matching is case-insensitive and by word: every
    /// word of the query must appear somewhere in the entry, so "run query"
    /// finds "Run Query" and "query run" finds it too.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = entry.searchText.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
