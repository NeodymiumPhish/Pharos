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
        populate(popup, sentinel: sentinel, rows: values.map { Row(display: $0, value: $0) })
    }

    /// One row of a value popup: what the eye reads, what the code stores, and
    /// an optional leading image.
    ///
    /// `display` and `value` are separate because they are not always the same
    /// string. A schema popup shows the schema and stores the schema, so its
    /// two halves coincide; the tag popup shows a tag's NAME and stores its
    /// ID. Both arrive RAW — `populate` escapes `display` and never touches
    /// `value`, so no caller has to remember which half is which.
    struct Row {
        let display: String
        let value: String
        let image: NSImage?

        init(display: String, value: String, image: NSImage? = nil) {
            self.display = display
            self.value = value
            self.image = image
        }
    }

    /// The general form: rows whose displayed text differs from their stored
    /// value, optionally with a leading image.
    ///
    /// `sentinelTag` marks the sentinel row so a caller can identify it
    /// positively — read it back with `isSentinel(_:tag:)`. Without it the only
    /// signal is a nil `representedObject`, which a row that merely *forgot*
    /// its value shares, and one caller (`TagSheet`) branches its whole
    /// "create versus add to existing" mode on that answer.
    ///
    /// **A tag of 0 marks nothing.** Every value row leaves `NSMenuItem.tag` at
    /// its default of 0, so comparing against 0 would match every row. Pass nil
    /// (the default, for the callers that never look) or a non-zero tag.
    ///
    /// Note the sentinel's title is NOT escaped, while every row's is: a
    /// sentinel is always an in-app literal ("None", "New tag"), never captured
    /// data. If that ever stops being true, escape it here.
    static func populate(
        _ popup: NSPopUpButton,
        sentinel: String?,
        sentinelTag: Int? = nil,
        rows: [Row]
    ) {
        // A tag with no sentinel to put it on is a programming error, and a
        // silent one: the tag simply vanishes and the caller's `isSentinel`
        // test then never matches anything.
        assert(sentinelTag == nil || sentinel != nil,
               "sentinelTag was given without a sentinel row to carry it")
        popup.removeAllItems()
        guard let menu = popup.menu else { return }
        if let sentinel {
            let item = NSMenuItem(title: sentinel, action: nil, keyEquivalent: "")
            item.representedObject = nil
            if let sentinelTag { item.tag = sentinelTag }
            menu.addItem(item)
        }
        for row in rows {
            let item = NSMenuItem(title: DisplayEscape.escaped(row.display), action: nil, keyEquivalent: "")
            item.representedObject = row.value
            item.image = row.image
            menu.addItem(item)
        }
    }

    /// Whether `item` is the sentinel row carrying `tag`.
    ///
    /// **Answers true for a nil item**, and that is the load-bearing part: a
    /// caller asking this is deciding a MODE, and "no selection" must fall to
    /// the same side as the sentinel. `TagSheet` disables its name, colour and
    /// note fields when this is false; if a nil selection answered false, the
    /// sheet would show "Add to Tag" with those fields disabled while its save
    /// path — which sees a nil target id — created a new tag instead.
    ///
    /// Exists as a function rather than a comparison at the call site so that
    /// rule is stated once and can be tested; the sheet that needs it has no
    /// test harness of its own.
    static func isSentinel(_ item: NSMenuItem?, tag: Int) -> Bool {
        guard let item else { return true }
        return item.tag == tag
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
