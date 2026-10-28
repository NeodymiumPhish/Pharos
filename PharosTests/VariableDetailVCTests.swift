// Standalone test runner for VariableDetailVC, the Variable Manager's form —
// compiled by scripts/test-variable-detail-vc.sh. Real AppKit: the form is
// hosted at a REQUIRED width (a window grows rather than compressing) in a
// titled window ordered in offscreen at (-20000, -20000), so field editors,
// the key-view loop and popovers all exist.
//
// Covers: the form's sections and rows per type, each value editor (growing
// text view, Number's live check, Bool, Date / Timestamp pickers and the
// calendar popover, the zone pop-up, List paste), type changes converting the
// value, "Renders as", the name-collision refusal and settle points, the
// store-republish rule, constraint conflicts, and an offscreen render of
// every editor kind in Light and Dark.
import AppKit

private var failures = 0

private func expectTrue(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let text = detail()
        print("FAIL \(name)" + (text.isEmpty ? "" : "\n  \(text)"))
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.5, _ name: String) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

// MARK: - Harness

/// Counts constraint conflicts, transient ones included (see
/// scripts/test-constraint-swap.sh). AppKit reports one conflict once per
/// process, so the conflict test runs first, on fresh views.
private final class SpyWindow: NSWindow {
    static var conflicts = 0
    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        if !(constraints ?? []).isEmpty { Self.conflicts += 1 }
    }
}

private final class Hosted {
    let window: SpyWindow
    let vc: VariableDetailVC
    var changes: [QueryVariable] = []
    var backs = 0
    var deletes = 0

    init(_ variable: QueryVariable, width: CGFloat = 520, height: CGFloat = 760,
         connections: VariableConnectionsView? = nil, otherNames: Set<String> = []) {
        window = SpyWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                           backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = container
        vc = VariableDetailVC(variable: variable, connectionsView: connections)
        vc.otherNames = otherNames
        vc.onChange = { [unowned self] in self.changes.append($0) }
        vc.onBack = { [unowned self] in self.backs += 1 }
        vc.onDelete = { [unowned self] in self.deletes += 1 }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.widthAnchor.constraint(equalToConstant: width),
            vc.view.heightAnchor.constraint(equalToConstant: height),
        ])
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        settle()
    }

    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        vc.dateControl.closePopover()
        vc.timestampControl.closePopover()
        window.orderOut(nil)
    }

    /// Types into a field through its real field editor, as the user would.
    /// Refuses a field the user could not type in.
    func type(_ text: String, into field: NSTextField, replacing: Bool = true) {
        guard field.isEnabled, field.isEditable, field.window != nil else {
            expectTrue(false, "setup: \(field.accessibilityIdentifier()) can be typed in")
            return
        }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            expectTrue(false, "setup: \(field.accessibilityIdentifier()) has a field editor")
            return
        }
        if replacing { editor.selectAll(nil) }
        editor.insertText(text, replacementRange: editor.selectedRange())
        settle()
    }

    /// Types into the value text view at `range` (default: replace all).
    func typeValue(_ text: String, replacing range: NSRange? = nil) {
        let tv = vc.valueTextView
        window.makeFirstResponder(tv)
        let target = range ?? NSRange(location: 0, length: (tv.string as NSString).length)
        tv.setSelectedRange(target)
        tv.insertText(text, replacementRange: target)
        settle()
    }

    var rowTitles: [String] {
        allDescendants(of: vc.view).compactMap { ($0 as? SettingsRow)?.titleLabel.stringValue }
    }

    func row(_ title: String) -> SettingsRow? {
        allDescendants(of: vc.view).compactMap { $0 as? SettingsRow }.first { $0.titleLabel.stringValue == title }
    }

    func shows(_ view: NSView) -> Bool { view.isDescendant(of: vc.view) && view.window != nil }
}

private func allDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants(of: $0) }
}

private func press(_ control: NSControl) {
    guard let action = control.action else { return }
    _ = NSApp.sendAction(action, to: control.target, from: control)
}

private func choose(_ segment: Int, in control: NSSegmentedControl) {
    control.selectedSegment = segment
    press(control)
}

private func choose(_ title: String, in popup: NSPopUpButton) {
    popup.selectItem(withTitle: title)
    press(popup)
}

private let utc = TimeZone(identifier: "UTC")!

/// A UTC-bound date for stored fields, through the rules' own parser.
private func date(_ text: String, _ type: VariableType) -> Date {
    VariableValueRules.dateTime(from: text, as: type)!.date
}

/// Ambiguous views the user can see. Skipped: hidden views (SettingsRow's
/// empty caption label keeps no vertical pin while hidden) and AppKit's
/// private views (a field editor's `_NSText…` internals lay out by frame).
private func hasAmbiguousLayoutRecursively(_ view: NSView) -> [NSView] {
    let counts = view.hasAmbiguousLayout && !view.isHiddenOrHasHiddenAncestor
        && !NSStringFromClass(type(of: view)).hasPrefix("_")
    return (counts ? [view] : []) + view.subviews.flatMap(hasAmbiguousLayoutRecursively)
}

// MARK: - Rendering (SettingsFurnitureTests' Rendered wrapper)

private final class Rendered {
    let rep: NSBitmapImageRep
    let scale: Int
    init(rep: NSBitmapImageRep, pointWidth: CGFloat) {
        self.rep = rep
        scale = max(1, Int((CGFloat(rep.pixelsWide) / pointWidth).rounded()))
    }

    /// The pixel at a POINT coordinate, top-left origin as `colorAt` counts.
    func pixel(_ x: Int, _ y: Int) -> NSColor? {
        rep.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB)
    }

    /// Pixels (not points) that read as the system red.
    var redPixels: Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.75, c.greenComponent < 0.45, c.blueComponent < 0.45 { count += 1 }
            }
        }
        return count
    }
}

/// Renders `view` under `appearance` — set on the view too, because
/// `cacheDisplay` restores each view's own appearance (lessons, 2026-09-19).
private func render(_ view: NSView, appearance: NSAppearance) -> Rendered? {
    view.appearance = appearance
    view.window?.appearance = appearance
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    appearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    return Rendered(rep: rep, pointWidth: view.bounds.width)
}

private func channelsWithin(_ a: NSColor?, _ b: NSColor?, _ tolerance: CGFloat) -> Bool {
    guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) <= tolerance
        && abs(a.greenComponent - b.greenComponent) <= tolerance
        && abs(a.blueComponent - b.blueComponent) <= tolerance
}

private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor? {
    var out: NSColor?
    appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
    return out
}

// MARK: - 1. Constraint conflicts and ambiguity (first: one report per process)

private func testNoConflictsForAnyEditor() {
    let before = SpyWindow.conflicts
    let variables: [QueryVariable] = [
        QueryVariable(name: "lit", value: "abc"),
        QueryVariable(name: "multi", value: (1...20).map(String.init).joined(separator: "\n"), type: .text),
        QueryVariable(name: "num", value: "4x", type: .number),
        QueryVariable(name: "flag", value: "t", type: .bool),
        QueryVariable(name: "day", value: "2026-10-28", type: .date),
        QueryVariable(name: "rel", value: "today", type: .date),
        QueryVariable(name: "at", value: "2026-10-28 14:30:00", type: .timestamp),
        QueryVariable(name: "atz", value: "2026-10-28 14:30:00 Europe/Paris", type: .timestamptz),
        QueryVariable(name: "ids", value: "1\nx", type: .numberList),
    ]
    for variable in variables {
        for width: CGFloat in [460, 700] {
            let host = Hosted(variable, width: width, connections: VariableConnectionsView())
            let ambiguous = hasAmbiguousLayoutRecursively(host.vc.view)
            expectTrue(ambiguous.isEmpty, "layout: \(variable.type.rawValue) at \(Int(width)) pt is not ambiguous",
                       ambiguous.map { "\(type(of: $0))" }.joined(separator: ", "))
            host.close()
        }
    }
    // Type changes rebuild the boxes; walk every family on one form.
    let host = Hosted(QueryVariable(name: "walk", value: "1"), width: 460)
    for title in VariableTypeFamily.allCases.map(\.displayName) + ["Literal"] {
        choose(title, in: host.vc.typePopup)
        host.settle()
    }
    host.vc.timeZoneSwitch.state = .on
    choose("Timestamp", in: host.vc.typePopup)
    host.settle()
    host.close()
    expectEqual(SpyWindow.conflicts - before, 0, "layout: no constraint conflict for any editor, width or type change")
}

// MARK: - 2. Form structure

private func testFormStructure() {
    let host = Hosted(QueryVariable(name: "target_ip", value: "10.0.0.1"), connections: VariableConnectionsView())
    defer { host.close() }
    let ids = Set(allDescendants(of: host.vc.view).map { $0.accessibilityIdentifier() })
    for section in ["variable", "value", "connections"] {
        expectTrue(ids.contains("settings.section.\(section)"), "form: a \(section) section header")
    }
    expectEqual(host.rowTitles, ["Name", "Type", "Value", "Renders as"], "form: Literal rows, in order")
    expectTrue(host.vc.connectionsView.map(host.shows) ?? false, "form: the Connections view is in the form")
    expectTrue(allDescendants(of: host.vc.view).contains { $0 is SettingsGroupBox && $0.subviews.first.map {
        allDescendants(of: $0).contains { $0 === host.vc.connectionsView } } ?? false },
        "form: inside a group box")
    expectEqual(host.vc.typePopup.itemTitles, ["Literal", "Text", "Number", "Bool", "Date", "Timestamp", "List"],
                "Type: one entry per family")
    expectEqual(host.vc.typePopup.titleOfSelectedItem, "Literal", "Type: the variable's family is chosen")
    expectEqual(host.vc.nameField.stringValue, "target_ip", "Name: the name")
    expectTrue(host.vc.nameField.font?.isFixedPitch == true, "Name: monospaced")
    expectTrue(host.vc.deleteButton.hasDestructiveAction && host.shows(host.vc.deleteButton),
               "Delete Variable: a destructive button in the form")
    press(host.vc.deleteButton)
    expectEqual(host.deletes, 1, "Delete Variable: calls onDelete")
    expectTrue(host.vc.rendersAsLabel.isSelectable, "Renders as: selectable")
    expectTrue(host.vc.rendersAsLabel.font?.isFixedPitch == true, "Renders as: monospaced")

    let bare = Hosted(QueryVariable(name: "x", value: "1"))
    defer { bare.close() }
    expectTrue(!Set(allDescendants(of: bare.vc.view).map { $0.accessibilityIdentifier() })
        .contains("settings.section.connections"), "form: no Connections section without a view to show")

    let stamp = Hosted(QueryVariable(name: "at", value: "now", type: .timestamp))
    defer { stamp.close() }
    expectEqual(stamp.rowTitles, ["Name", "Type", "With time zone", "Value", "Renders as"],
                "Timestamp: a With time zone switch; Now has no picker")
    let list = Hosted(QueryVariable(name: "ids", value: "a", type: .numberList))
    defer { list.close() }
    expectEqual(list.rowTitles, ["Name", "Type", "Items are", "Items", "Renders as"], "List: an Items are pop-up")
    expectEqual(list.vc.listElementPopup.titleOfSelectedItem, "Number", "List: showing the element type")
}

// MARK: - 3. Type changes convert the value

private func testTypeChangeConverts() {
    let host = Hosted(QueryVariable(name: "v", value: "2026-10-28"))
    defer { host.close() }
    choose("Date", in: host.vc.typePopup)
    expectEqual(host.vc.variable.type, .date, "type: Date chosen")
    expectEqual(host.vc.variable.value, "2026-10-28", "type: a date-shaped Literal stays the date")
    expectEqual(host.changes.last?.type, .date, "type: onChange carries the new type")

    choose("Timestamp", in: host.vc.typePopup)
    expectEqual(host.vc.variable.value, "2026-10-28 00:00:00", "type: Date → Timestamp adds midnight")
    host.vc.timeZoneSwitch.state = .on
    press(host.vc.timeZoneSwitch)
    expectEqual(host.vc.variable.type, .timestamptz, "type: With time zone makes it zoned")
    expectEqual(host.vc.variable.value, "2026-10-28 00:00:00 " + TimeZone.current.identifier,
                "type: and adds this Mac's zone")

    let list = Hosted(QueryVariable(name: "l", value: "a, b, c", type: .text))
    defer { list.close() }
    choose("List", in: list.vc.typePopup)
    expectEqual(list.vc.variable.type, .textList, "type: List of Text by default")
    expectEqual(list.vc.variable.value, "a\nb\nc", "type: a CSV value becomes one item per line")
    expectEqual(list.vc.valueTextView.string, "a\nb\nc", "type: and the editor shows it")
    choose("Number", in: list.vc.listElementPopup)
    expectEqual(list.vc.variable.type, .numberList, "type: Items are Number")

    let today = Hosted(QueryVariable(name: "d", value: "today", type: .date))
    defer { today.close() }
    choose("Timestamp", in: today.vc.typePopup)
    expectEqual(today.vc.variable.value, "now", "type: today becomes now")
    let number = Hosted(QueryVariable(name: "n", value: "  42 \n"))
    defer { number.close() }
    choose("Number", in: number.vc.typePopup)
    expectEqual(number.vc.variable.value, "42", "type: to Number trims")
    expectTrue(number.shows(number.vc.numberField), "type: and swaps in the Number field")
    expectTrue(!number.shows(number.vc.textEditor), "type: the text editor is gone")
}

// MARK: - 4. Number: live check

private func testNumberLiveCheck() {
    let host = Hosted(QueryVariable(name: "port", value: "443", type: .number))
    defer { host.close() }
    expectTrue(!host.vc.numberField.showsError, "Number: a good value has no error outline")
    expectEqual(host.vc.valueRow?.caption ?? "", "", "Number: and no caption")

    host.type("4x", into: host.vc.numberField)
    expectEqual(host.vc.variable.value, "4x", "Number: a bad value keeps its text")
    expectEqual(host.changes.last?.value, "4x", "Number: and is written on the keystroke")
    expectTrue(host.vc.numberField.showsError, "Number: the field shows the error outline")
    let caption = host.vc.valueRow?.caption ?? ""
    expectTrue(caption.contains("not a valid number") && caption.contains("4x"), "Number: the caption says why", caption)
    expectEqual(host.vc.valueRow?.captionLabel.textColor, NSColor.systemRed, "Number: in red")
    expectEqual(host.vc.valueRow?.captionLabel.accessibilityIdentifier(), "variables.value.caption",
                "Number: the caption label carries the identifier")
    expectEqual(host.vc.rendersAsLabel.textColor, NSColor.systemRed, "Renders as: red for a bad value")
    expectTrue(host.vc.rendersAsLabel.stringValue.contains("not a valid number"), "Renders as: with the reason")

    // The outline is drawn: red pixels in the field while it shows, and
    // (nearly) none once the value is good. Light and Dark.
    for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        host.type("4x", into: host.vc.numberField)
        host.window.makeFirstResponder(nil)
        let bad = render(host.vc.numberField, appearance: appearance)?.redPixels ?? 0
        host.type("42", into: host.vc.numberField)
        host.window.makeFirstResponder(nil)
        let good = render(host.vc.numberField, appearance: appearance)?.redPixels ?? 0
        expectTrue(bad > 200 && good < 20, "Number (\(name)): the error outline is drawn red, and goes",
                   "red pixels bad \(bad), good \(good)")
        host.vc.numberField.appearance = nil
        host.window.appearance = nil
    }
    expectEqual(host.vc.variable.value, "42", "Number: a good value")
    expectTrue(!host.vc.numberField.showsError, "Number: clears the outline")
    expectEqual(host.vc.rendersAsLabel.stringValue, "42", "Renders as: the number")
}

// MARK: - 5. Date

private func testDateEditor() {
    let host = Hosted(QueryVariable(name: "day", value: "2026-10-28", type: .date))
    defer { host.close() }
    expectEqual(host.vc.dateModeControl.selectedSegment, 0, "Date: a fixed value shows Fixed")
    expectEqual(host.vc.dateModeControl.label(forSegment: 1), "Today", "Date: the other segment is Today")
    expectEqual(host.rowTitles, ["Name", "Type", "Value", "Date", "Renders as"], "Date: a Date row under Fixed")
    let picker = host.vc.dateControl.textualPicker
    expectEqual(picker.datePickerStyle, .textFieldAndStepper, "Date: a textual picker")
    expectEqual(picker.datePickerElements, [.yearMonthDay], "Date: year, month, day")
    expectEqual(picker.timeZone?.secondsFromGMT(), 0, "Date: bound in UTC")
    expectEqual(VariableValueRules.format(picker.dateValue, timeZone: utc, as: .date), "2026-10-28",
                "Date: the picker shows the stored date")
    expectEqual(host.vc.rendersAsLabel.stringValue, "DATE '2026-10-28'", "Renders as: the DATE literal")

    picker.dateValue = date("2025-01-15", .date)
    press(picker)
    expectEqual(host.vc.variable.value, "2025-01-15", "Date: the picker writes YYYY-MM-DD")
    expectEqual(host.changes.last?.value, "2025-01-15", "Date: through onChange")

    // The calendar popover: a graphical picker, in step with the textual one.
    host.vc.dateControl.calendarButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    expectEqual(host.vc.dateControl.calendarButton.image?.accessibilityDescription, "Show Calendar",
                "calendar: the button is labelled")
    expectTrue(host.vc.dateControl.popover?.isShown == true, "calendar: the button opens the popover")
    if let graphical = host.vc.dateControl.graphicalPicker {
        expectEqual(graphical.datePickerStyle, .clockAndCalendar, "calendar: a graphical picker")
        expectEqual(VariableValueRules.format(graphical.dateValue, timeZone: utc, as: .date), "2025-01-15",
                    "calendar: showing the value")
        expectTrue(graphical.frame.width > 100 && graphical.frame.height > 100,
                   "calendar: the picker has its size after the show", "\(graphical.frame.size)")
        graphical.dateValue = date("2024-02-29", .date)
        press(graphical)
        expectEqual(host.vc.variable.value, "2024-02-29", "calendar: a pick writes the value")
        expectEqual(VariableValueRules.format(picker.dateValue, timeZone: utc, as: .date), "2024-02-29",
                    "calendar: and the textual picker follows")
    } else {
        expectTrue(false, "calendar: a graphical picker was made")
    }
    host.vc.dateControl.closePopover()

    choose(1, in: host.vc.dateModeControl)
    expectEqual(host.vc.variable.value, "today", "Today writes today")
    expectTrue(!host.shows(host.vc.dateControl), "Today: no picker")
    expectEqual(host.vc.rendersAsLabel.stringValue, "CURRENT_DATE", "Renders as: CURRENT_DATE")
    choose(0, in: host.vc.dateModeControl)
    expectEqual(host.vc.variable.value, VariableValueRules.format(Date(), timeZone: .current, as: .date),
                "Fixed: starts from today's date here")
    expectTrue(host.shows(host.vc.dateControl), "Fixed: the picker is back")
}

// MARK: - 6. Timestamp with time zone

private func testTimestampWithZone() {
    let host = Hosted(QueryVariable(name: "at", value: "2026-10-28 14:30:00 Europe/Paris", type: .timestamptz))
    defer { host.close() }
    expectEqual(host.rowTitles, ["Name", "Type", "With time zone", "Value", "Date and time", "Time zone", "Renders as"],
                "Timestamp tz: date-time and zone rows")
    expectEqual(host.vc.timeZoneSwitch.state, .on, "Timestamp tz: the switch is on")
    expectEqual(host.vc.timestampModeControl.label(forSegment: 1), "Now", "Timestamp: the other segment is Now")
    let picker = host.vc.timestampControl.textualPicker
    expectEqual(picker.datePickerElements, [.yearMonthDay, .hourMinuteSecond], "Timestamp: date and time")
    expectEqual(VariableValueRules.format(picker.dateValue, timeZone: utc, as: .timestamp), "2026-10-28 14:30:00",
                "Timestamp tz: the picker shows the wall-clock time")
    expectEqual(host.vc.zonePopup.titleOfSelectedItem, "Europe/Paris", "zone: the stored zone is chosen")
    let titles = host.vc.zonePopup.itemArray.map { $0.isSeparatorItem ? "—" : $0.title }
    expectEqual(titles.first, "UTC", "zone: UTC first")
    let pinned = TimeZoneChoices.pinned()
    expectEqual(Array(titles.prefix(pinned.count + 1)), pinned + ["—"], "zone: then this Mac's zone, then a separator")
    expectTrue(titles.count > 300 && titles.contains("America/New_York"), "zone: then every zone", "\(titles.count)")

    choose("America/New_York", in: host.vc.zonePopup)
    expectEqual(host.vc.variable.value, "2026-10-28 14:30:00 America/New_York",
                "zone: a new zone keeps the wall-clock time")
    picker.dateValue = date("2027-01-02 03:04:05", .timestamp)
    press(picker)
    expectEqual(host.vc.variable.value, "2027-01-02 03:04:05 America/New_York", "Timestamp tz: the picker writes … <zone id>")
    expectTrue(host.vc.rendersAsLabel.stringValue.hasPrefix("TIMESTAMPTZ '2027-01-02 03:04:05-05:00'"),
               "Renders as: the zoned literal", host.vc.rendersAsLabel.stringValue)

    host.vc.timestampControl.calendarButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    expectEqual(host.vc.timestampControl.graphicalPicker?.datePickerElements, [.yearMonthDay, .hourMinuteSecond],
                "calendar: a timestamp's popover has the clock too")
    host.vc.timestampControl.closePopover()

    choose(1, in: host.vc.timestampModeControl)
    expectEqual(host.vc.variable.value, "now", "Now writes now")
    expectTrue(!host.shows(host.vc.zonePopup), "Now: no zone")
    expectEqual(host.vc.rendersAsLabel.stringValue, "CURRENT_TIMESTAMP", "Renders as: CURRENT_TIMESTAMP")

    let utcStamp = Hosted(QueryVariable(name: "u", value: "2026-01-01 00:00:00 UTC", type: .timestamptz))
    defer { utcStamp.close() }
    expectEqual(utcStamp.vc.zonePopup.titleOfSelectedItem, "UTC", "zone: UTC stays UTC (not GMT)")
    utcStamp.vc.timestampControl.textualPicker.dateValue = date("2026-01-01 08:00:00", .timestamp)
    press(utcStamp.vc.timestampControl.textualPicker)
    expectEqual(utcStamp.vc.variable.value, "2026-01-01 08:00:00 UTC", "zone: written back as UTC")
}

// MARK: - 7. List

private func testListEditor() {
    let host = Hosted(QueryVariable(name: "ids", value: "", type: .textList))
    defer { host.close() }
    let board = NSPasteboard(name: NSPasteboard.Name("com.pharos.tests.variable-detail.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    func paste(_ text: String, at range: NSRange) {
        board.clearContents()
        board.setString(text, forType: .string)
        host.window.makeFirstResponder(host.vc.valueTextView)
        host.vc.valueTextView.setSelectedRange(range)
        _ = host.vc.valueTextView.readSelection(from: board)
        host.settle()
    }

    paste("a, b, c", at: NSRange(location: 0, length: 0))
    expectEqual(host.vc.variable.value, "a\nb\nc", "List paste: a CSV row becomes three lines")
    expectEqual(host.changes.last?.value, "a\nb\nc", "List paste: written through onChange")
    expectEqual(host.vc.valueRow?.caption ?? "", "3 items", "List: the caption counts the items")
    expectEqual(host.vc.rendersAsLabel.stringValue, "('a', 'b', 'c')", "Renders as: the IN list")
    expectEqual(host.vc.valueTextView.font?.isFixedPitch, true, "List paste: keeps the editor's font")

    // Into the middle of a line: the items go on lines of their own.
    paste("'x'\t'y'", at: NSRange(location: 1, length: 0))
    expectEqual(host.vc.variable.value, "a\nx\ny\nb\nc", "List paste: mid-line, on lines of their own")
    paste("1;2", at: NSRange(location: 4, length: 0))
    expectEqual(host.vc.variable.value, "a\nx\n1\n2\ny\nb\nc", "List paste: a break after the items when text follows")
    // One item is inserted as typed, quotes stripped, no line breaks added.
    host.typeValue("ab")
    paste("'q'", at: NSRange(location: 1, length: 0))
    expectEqual(host.vc.variable.value, "aqb", "List paste: one item goes in as is")

    let numbers = Hosted(QueryVariable(name: "n", value: "1\n2\nx\n4", type: .numberList))
    defer { numbers.close() }
    expectEqual(numbers.vc.valueRow?.caption ?? "", "4 items · 1 not a number (line 3)",
                "List of numbers: the caption names the bad line")
    numbers.typeValue("1\ny\n3\nz")
    expectEqual(numbers.vc.valueRow?.caption ?? "", "4 items · 2 not numbers (lines 2, 4)", "List of numbers: two bad lines")
    expectEqual(numbers.vc.rendersAsLabel.textColor, NSColor.systemRed, "Renders as: red for a bad list")

    // Literal does not split a paste.
    let literal = Hosted(QueryVariable(name: "l", value: ""))
    defer { literal.close() }
    board.clearContents()
    board.setString("a, b", forType: .string)
    literal.window.makeFirstResponder(literal.vc.valueTextView)
    _ = literal.vc.valueTextView.readSelection(from: board)
    expectEqual(literal.vc.variable.value, "a, b", "Literal paste: pasted as is")
}

// MARK: - 8. The growing text editor

private func testGrowingEditor() {
    let host = Hosted(QueryVariable(name: "v", value: "one line"))
    defer { host.close() }
    let editor = host.vc.textEditor
    let oneLine = editor.height(forVisibleLines: 1, horizontalScroller: 0)
    expectClose(editor.frame.height, oneLine, "editor: one line high for one line")
    expectTrue(editor.gutter.isHidden, "editor: no line numbers for one line")
    expectEqual(host.vc.valueRow?.caption ?? "", "8 chars", "editor: the size caption")

    host.typeValue("1\n2\n3\n4\n5")
    expectClose(editor.frame.height, editor.height(forVisibleLines: 5, horizontalScroller: 0),
                "editor: grows to five lines as they are typed")
    expectTrue(!editor.gutter.isHidden && editor.gutter.frame.width > 0, "editor: line numbers from two lines")
    let clip = editor.scrollView.contentView.bounds.height
    expectTrue(editor.textView.frame.height <= clip + 0.5, "editor: five lines fit without scrolling",
               "text \(editor.textView.frame.height), clip \(clip)")

    host.typeValue((1...30).map(String.init).joined(separator: "\n"))
    expectClose(editor.frame.height, editor.height(forVisibleLines: 12, horizontalScroller: 0),
                "editor: stops at twelve lines")
    expectTrue(editor.textView.frame.height > editor.scrollView.contentView.bounds.height + 10,
               "editor: and scrolls past them")

    host.typeValue("short")
    expectClose(editor.frame.height, oneLine, "editor: shrinks back to one line")
    expectTrue(editor.gutter.isHidden, "editor: and drops the line numbers")

    // A click anywhere in the box lands in the text view.
    let point = editor.convert(NSPoint(x: editor.bounds.maxX - 20, y: editor.bounds.midY), to: nil)
    let hit = host.window.contentView?.hitTest(host.window.contentView!.convert(point, from: nil))
    expectTrue(hit === editor.textView, "editor: a click beside short text hits the text view",
               "hit \(hit.map { "\(type(of: $0))" } ?? "nil")")

    // Placeholder only while empty.
    host.typeValue("")
    expectTrue(!editor.placeholderLabel.isHidden && editor.placeholderLabel.stringValue == "value",
               "editor: the placeholder shows while empty")
    expectEqual(host.vc.rendersAsLabel.textColor, NSColor.systemRed, "Renders as: red for an empty Literal")
    host.typeValue("x")
    expectTrue(editor.placeholderLabel.isHidden, "editor: and hides with text")
}

// MARK: - 9. Renders as

/// "Renders as" spans its row and wraps at words. It once hugged its text:
/// after "42" it was a 16 pt column, so the next value wrapped two characters
/// to a line ("DA/TE"), and the same hug pulled the Variable Manager window
/// narrower (scripts/test-variable-manager.sh measures that).
private func testRendersAsFillsTheRow() {
    let host = Hosted(QueryVariable(name: "d", value: "42"))
    defer { host.close() }
    let label = host.vc.rendersAsLabel
    func check(_ when: String, maxLines: Int) {
        host.settle()
        guard let row = host.vc.rendersAsRow else {
            expectTrue(false, "Renders as \(when): the row is on show")
            return
        }
        // Alignment rects: a label's frame runs 2 pt past its text each side.
        let content = row.bounds.width - 2 * SettingsMetrics.rowInsetH
        let width = label.alignmentRect(forFrame: label.frame).width
        expectClose(width, content, tolerance: 1, "Renders as \(when): spans the row (\(width) of \(content))")
        let lineHeight = label.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 14
        let lines = Int((label.frame.height / lineHeight).rounded())
        expectTrue(lines >= 1 && lines <= maxLines, "Renders as \(when): \(lines) line(s), at most \(maxLines)",
                   "height \(label.frame.height), line \(lineHeight)")
    }
    expectEqual(label.lineBreakMode, .byWordWrapping, "Renders as: wraps at word boundaries")
    expectEqual(label.stringValue, "42", "Renders as: the short value first")
    check("after \"42\"", maxLines: 1)
    host.typeValue("CURRENT_DATE - INTERVAL '30 days' AND a long tail of words that runs past one line")
    check("then a long value", maxLines: 3)

    let number = Hosted(QueryVariable(name: "n", value: "42", type: .number))
    defer { number.close() }
    number.type("4x is not a number at all and the sentence that says so is long", into: number.vc.numberField)
    number.settle()
    if let row = number.vc.rendersAsRow {
        let content = row.bounds.width - 2 * SettingsMetrics.rowInsetH
        let label = number.vc.rendersAsLabel
        expectClose(label.alignmentRect(forFrame: label.frame).width, content, tolerance: 1,
                    "Renders as: the invalid-value sentence spans the row too")
    } else {
        expectTrue(false, "Renders as: the Number row is on show")
    }
}

private func testRendersAs() {
    let cases: [(QueryVariable, String)] = [
        (QueryVariable(name: "t", value: "O'Brien", type: .text), "'O''Brien'"),
        (QueryVariable(name: "b", value: "t", type: .bool), "true"),
        (QueryVariable(name: "n", value: "NULL", type: .bool), "NULL"),
        (QueryVariable(name: "l", value: "now()"), "now()"),
        (QueryVariable(name: "ts", value: "2026-10-28 01:02:03", type: .timestamp), "TIMESTAMP '2026-10-28 01:02:03'"),
    ]
    for (variable, sql) in cases {
        let host = Hosted(variable)
        expectEqual(host.vc.rendersAsLabel.stringValue, sql, "Renders as: \(variable.type.rawValue) \(variable.value)")
        expectEqual(host.vc.rendersAsLabel.textColor, NSColor.labelColor, "Renders as: in the label colour")
        expectEqual(host.vc.rendersAsRow?.titleLabel.stringValue, "Renders as", "Renders as: its row")
        host.close()
    }
}

// MARK: - 10. Bool

private func testBool() {
    for (index, choice) in VariableSubstitutor.BoolChoice.allCases.enumerated() {
        expectEqual(VariableDetailVC.boolSegmentLabels[index].lowercased(), choice.rawValue.lowercased(),
                    "Bool: segment \(index) is \(choice.rawValue)")
    }
    let host = Hosted(QueryVariable(name: "flag", value: "yes", type: .bool))
    defer { host.close() }
    expectEqual(host.vc.boolControl.selectedSegment, 0, "Bool: 'yes' selects True")
    choose(2, in: host.vc.boolControl)
    expectEqual(host.vc.variable.value, "NULL", "Bool: NULL writes the canonical NULL")
    expectEqual(host.changes.count, 1, "Bool: one onChange per choice")
    let unset = Hosted(QueryVariable(name: "f", value: "abc", type: .bool))
    defer { unset.close() }
    expectEqual(unset.vc.boolControl.selectedSegment, -1, "Bool: a value that means none selects nothing")
}

// MARK: - 11. Name: collision refusal and settle points

private func testNameCollision() {
    let host = Hosted(QueryVariable(name: "env", value: "prod"), otherNames: ["limit"])
    defer { host.close() }
    host.type("limit", into: host.vc.nameField)
    expectTrue(host.vc.isNameCollision, "collision: typing an existing name collides")
    expectEqual(host.vc.variable.name, "env", "collision: never reaches the model")
    expectTrue(host.changes.isEmpty, "collision: and fires no onChange")
    expectEqual(host.vc.nameField.textColor, NSColor.systemRed, "collision: the name goes red")
    let notice = host.vc.collisionNoticeRow?.titleLabel.stringValue ?? ""
    expectTrue(notice.contains("\"limit\"") && notice.contains("already exists"), "collision: the Value box says so", notice)
    expectEqual(host.rowTitles.count, 3, "collision: the notice stands in for the value rows")
    expectTrue(!host.shows(host.vc.textEditor), "collision: the value editor is gone")

    host.vc.cancelOperation(nil)
    expectEqual(host.backs, 0, "collision: Escape is refused")
    expectTrue(host.window.firstResponder === host.vc.nameField.currentEditor(), "collision: focus goes back to the name")
    host.vc.settleForDismissal()
    expectEqual(host.vc.variable.name, "env", "collision: a forced dismissal drops the colliding name")

    host.type("limits ", into: host.vc.nameField)
    expectTrue(!host.vc.isNameCollision, "collision: clears with a unique name")
    expectTrue(host.shows(host.vc.textEditor), "collision: the value editor is back")
    expectEqual(host.vc.variable.name, "env", "settle: a unique name waits for a settle point")
    host.vc.cancelOperation(nil)
    expectEqual(host.backs, 1, "settle: Escape leaves once unique")
    expectEqual(host.vc.variable.name, "limits", "settle: and commits the trimmed name")
    expectEqual(host.changes.count, 1, "settle: exactly once")
    host.vc.settleForDismissal()
    expectEqual(host.changes.count, 1, "settle: a second settle point with no change fires nothing")

    // A committed collision (legacy duplicate data) shows before any typing.
    let legacy = Hosted(QueryVariable(name: "dup", value: "1"), otherNames: ["dup"])
    defer { legacy.close() }
    expectTrue(legacy.vc.isNameCollision && legacy.vc.collisionNoticeRow != nil, "collision: a committed duplicate shows at once")
    legacy.vc.setState(.init(duplication: .shadowed, problem: nil))
    expectEqual(legacy.vc.nameRow?.caption ?? "", "Redefined below — this row has no effect.",
                "duplication: the shadowed note is the Name row's caption")

    // An empty name never collides, even with another empty one.
    let blank = Hosted(QueryVariable(name: "", value: ""), otherNames: [""])
    defer { blank.close() }
    expectTrue(!blank.vc.isNameCollision, "collision: an empty name never collides")
}

// MARK: - 12. Keyboard: Tab, Shift-Tab, the caret

private func testKeyboard() {
    let host = Hosted(QueryVariable(name: "v", value: "abcdef"))
    defer { host.close() }
    // The next TEXT control after the name is the value editor.
    var next = host.vc.nameField.nextValidKeyView
    var steps = 0
    while let view = next, !(view is NSText || view is NSTextField), steps < 12 {
        next = view.nextValidKeyView
        steps += 1
    }
    expectTrue(next === host.vc.valueTextView, "Tab: the name's next text control is the value editor",
               "got \(next.map { "\(type(of: $0))" } ?? "nil")")
    host.window.makeFirstResponder(host.vc.valueTextView)
    host.vc.valueTextView.insertBacktab(nil)
    expectTrue(host.window.firstResponder === host.vc.nameField.currentEditor(), "Shift-Tab: back to the name")

    // The host's round trip on each keystroke (otherNames, setState) must not
    // move the caret.
    host.vc.onChange = { [unowned host] _ in
        host.vc.otherNames = ["zzz"]
        host.vc.setState(nil)
    }
    host.window.makeFirstResponder(host.vc.valueTextView)
    host.vc.valueTextView.setSelectedRange(NSRange(location: 3, length: 0))
    host.vc.valueTextView.insertText("X", replacementRange: NSRange(location: 3, length: 0))
    expectEqual(host.vc.variable.value, "abcXdef", "caret: the edit lands")
    expectEqual(host.vc.valueTextView.selectedRange().location, 4, "caret: stays after the typed character")
    host.vc.valueTextView.cancelOperation(nil)
    expectEqual(host.backs, 1, "Escape in the value editor goes through attemptBack")
}

// MARK: - 13. The store's republish

private func testAdoptExternalChange() {
    let host = Hosted(QueryVariable(name: "v", value: "one"))
    defer { host.close() }
    var incoming = host.vc.variable
    incoming.value = "two"
    host.window.makeFirstResponder(nil)
    host.vc.adoptExternalChange(incoming)
    expectEqual(host.vc.valueTextView.string, "two", "republish: adopted while nobody types")
    host.window.makeFirstResponder(host.vc.valueTextView)
    incoming.value = "three"
    host.vc.adoptExternalChange(incoming)
    expectEqual(host.vc.valueTextView.string, "two", "republish: ignored while the user types in the form")
    expectEqual(host.vc.variable.value, "two", "republish: the model too")
}

// MARK: - 14. Gutter alignment (defect 3), on the growing editor

private func groundTruthGutterY(line: Int, textView tv: NSTextView, gutter: LineNumberGutter) -> CGFloat? {
    guard let lm = tv.layoutManager else { return nil }
    let ns = tv.string as NSString
    let lines = tv.string.components(separatedBy: "\n")
    guard line >= 1, line <= lines.count else { return nil }
    let charIndex = lines[0..<(line - 1)].reduce(0) { $0 + $1.utf16.count + 1 }
    let lineRange = ns.lineRange(for: NSRange(location: min(charIndex, ns.length), length: 0))
    let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
    let lineRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    var rectInTextView = lineRect
    rectInTextView.origin.x += tv.textContainerInset.width
    rectInTextView.origin.y += tv.textContainerInset.height
    return tv.convert(rectInTextView, to: gutter).origin.y
}

private func testGutterAlignment() {
    for inset in [nil, NSSize(width: 4, height: 8)] as [NSSize?] {
        let host = Hosted(QueryVariable(name: "v", value: "line1\nline2\nline3\nline4\nline5"))
        let tv = host.vc.valueTextView
        if let inset { tv.textContainerInset = inset }
        host.vc.textEditor.needsUpdateConstraints = true
        host.settle()
        if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
        let gutter = host.vc.textEditor.gutter
        let label = inset == nil ? "default inset" : "SQLTextView-style inset"
        for line in 1...5 {
            let truth = groundTruthGutterY(line: line, textView: tv, gutter: gutter)
            let seam = gutter.y(forLine: line)
            expectTrue(truth != nil && seam != nil && abs(seam! - truth!) < 1,
                       "gutter (\(label)): line \(line) number aligns with its text",
                       "seam \(String(describing: seam)), text \(String(describing: truth))")
        }
        host.close()
    }
}

/// The gutter numbers every line on screen (`visibleCharacterRange`, a test
/// seam in LineNumberGutter): the range it draws and the lines `y(forLine:)`
/// puts inside its bounds are computed by different means and must agree.
/// The editor stops at 12 lines, so a 30-line value scrolls; checked at rest
/// and scrolled to the end.
private func testGutterNumbersEveryVisibleLine() {
    let host = Hosted(QueryVariable(name: "long", value: (1...30).map { "line \($0)" }.joined(separator: "\n")))
    defer { host.close() }
    let gutter = host.vc.textEditor.gutter
    let tv = host.vc.valueTextView
    if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
    let text = tv.string as NSString
    func line(at index: Int) -> Int {
        var line = 1
        for i in 0..<min(index, text.length) where text.character(at: i) == 0x0A { line += 1 }
        return line
    }
    for scrolledToEnd in [false, true] {
        if scrolledToEnd {
            tv.scrollRangeToVisible(NSRange(location: text.length, length: 0))
            host.settle()
        }
        let label = scrolledToEnd ? "scrolled to the end" : "unscrolled"
        let lineHeight = host.vc.textEditor.lineHeight
        let onScreen = (1...30).filter { number in
            guard let y = gutter.y(forLine: number) else { return false }
            return y >= 0 && y + lineHeight <= gutter.bounds.height + 0.5
        }
        guard let first = onScreen.first, let last = onScreen.last, let range = gutter.visibleCharacterRange() else {
            expectTrue(false, "gutter (\(label)): lines on screen and a visible range")
            continue
        }
        expectTrue(onScreen.count < 30, "gutter (\(label)): setup — the value is taller than the editor")
        expectTrue(line(at: range.location) <= first && line(at: max(range.location, NSMaxRange(range) - 1)) >= last,
                   "gutter (\(label)): the drawn range covers every line on screen (\(first)–\(last))")
    }
}

/// Mirrors `SQLTextView`'s shape, inset set INSIDE init — the discriminator
/// for defect 3 (see the history of this file). Guards the SQL editor against
/// a regression in `LineNumberGutter.y(forLine:)`.
private final class SQLEditorStyleTextView: NSTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        textContainerInset = NSSize(width: 4, height: 8)
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }
}

private func testSQLEditorStyleGutterAlignment() {
    let width: CGFloat = 300, height: CGFloat = 60
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container
    let textView = SQLEditorStyleTextView()
    textView.string = (1...8).map { "select \($0);" }.joined(separator: "\n")
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let scrollView = NSScrollView(frame: container.bounds)
    scrollView.hasVerticalScroller = true
    scrollView.documentView = textView
    let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
    gutter.frame = NSRect(x: 0, y: 0, width: gutter.desiredWidth, height: height)
    scrollView.frame = NSRect(x: gutter.frame.width, y: 0, width: width - gutter.frame.width, height: height)
    container.addSubview(gutter)
    container.addSubview(scrollView)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    container.layoutSubtreeIfNeeded()
    container.displayIfNeeded()
    if let tc = textView.textContainer { textView.layoutManager?.ensureLayout(for: tc) }

    func check(_ label: String) {
        for line in 1...3 {
            let truth = groundTruthGutterY(line: line, textView: textView, gutter: gutter)
            let seam = gutter.y(forLine: line)
            expectTrue(truth != nil && seam != nil && abs(seam! - truth!) < 1, "\(label): line \(line) aligns",
                       "seam \(String(describing: seam)), text \(String(describing: truth))")
        }
    }
    check("SQL-editor-style gutter, unscrolled")
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    expectTrue(scrollView.contentView.bounds.origin.y != 0, "setup: the clip view scrolled")
    check("SQL-editor-style gutter, scrolled")
}

// MARK: - 15. Offscreen render of every editor kind, Light and Dark

private func testRenderEveryEditor() {
    let kinds: [QueryVariable] = [
        QueryVariable(name: "lit", value: "a\nb\nc"),
        QueryVariable(name: "num", value: "4x", type: .number),
        QueryVariable(name: "flag", value: "true", type: .bool),
        QueryVariable(name: "day", value: "2026-10-28", type: .date),
        QueryVariable(name: "atz", value: "2026-10-28 14:30:00 Europe/Paris", type: .timestamptz),
        QueryVariable(name: "ids", value: "1\nx", type: .numberList),
    ]
    let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
    for variable in kinds {
        let host = Hosted(variable, width: 520, height: 700, connections: VariableConnectionsView())
        let renders = [light, dark].map { render(host.vc.view, appearance: $0) }
        guard let l = renders[0], let d = renders[1] else {
            expectTrue(false, "render: \(variable.type.rawValue) renders")
            host.close()
            continue
        }
        // The surface (left of the boxes: the pane inset is 20 pt) and the
        // Name row's plate, at the row's middle. Relative checks: the
        // absolute system colours differ between macOS releases.
        guard let nameRow = host.vc.nameRow,
              let valueBox = sequence(first: host.vc.rendersAsRow as NSView?, next: { $0?.superview })
                .compactMap({ $0 as? SettingsGroupBox }).first else {
            expectTrue(false, "render: \(variable.type.rawValue) has its rows")
            host.close()
            continue
        }
        let row = nameRow.convert(nameRow.bounds, to: host.vc.view)
        let y = Int(row.midY)
        let kind = variable.type.rawValue
        for (name, image) in [("light", l), ("dark", d)] {
            let surface = image.pixel(6, y), plate = image.pixel(Int(row.minX) + 4, y)
            expectTrue(!channelsWithin(surface, plate, 0.02), "render (\(kind), \(name)): the plate stands off the surface",
                       "surface \(String(describing: surface)), plate \(String(describing: plate))")
            // Ink in the Value box: text and control glyphs, not plate.
            let box = valueBox.convert(valueBox.bounds, to: host.vc.view).insetBy(dx: 2, dy: 2)
            var ink = 0
            for py in stride(from: Int(box.minY), to: Int(box.maxY), by: 1) {
                for px in stride(from: Int(box.minX), to: Int(box.maxX), by: 1) where !channelsWithin(image.pixel(px, py), plate, 0.2) {
                    ink += 1
                }
            }
            expectTrue(ink > 40, "render (\(kind), \(name)): the Value box draws its contents", "ink \(ink)")
        }
        expectTrue(!channelsWithin(l.pixel(6, y), d.pixel(6, y), 0.1),
                   "render (\(kind)): dark is not light (the pass is not vacuous)")
        host.close()
    }
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")

    testNoConflictsForAnyEditor()
    testFormStructure()
    testTypeChangeConverts()
    testNumberLiveCheck()
    testDateEditor()
    testTimestampWithZone()
    testListEditor()
    testGrowingEditor()
    testRendersAs()
    testRendersAsFillsTheRow()
    testBool()
    testNameCollision()
    testKeyboard()
    testAdoptExternalChange()
    testGutterAlignment()
    testGutterNumbersEveryVisibleLine()
    testSQLEditorStyleGutterAlignment()
    testRenderEveryEditor()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
