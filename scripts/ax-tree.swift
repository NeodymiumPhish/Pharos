// ax-tree — drive the rows of a running process's outline view: disclose them,
// open their context menu, and double-click them.
//
// Usage:
//   swiftc -O -o /tmp/ax-tree scripts/ax-tree.swift
//   /tmp/ax-tree <pid> rows
//   /tmp/ax-tree <pid> expand|collapse <row-text>
//   /tmp/ax-tree <pid> rightclick|doubleclick|click <row-text> [--offset N]
//
// <row-text> is matched against every AXStaticText inside a row: an EXACT match
// wins over a substring, so "dns_log" finds the root and not "dns_log_2013".
// Exit 2 on a usage error, 5 when no row matches, 6 when the action fails.
//
// Third tool beside ax-do (writes one control) and ax-walk (reads the tree),
// for the two things neither can do:
//
//   - DISCLOSURE. An outline row opens by its AXDisclosing attribute. ax-do's
//     `press` has nothing to press: the triangle is drawn by the row, not by a
//     child AXButton.
//   - THE CONTEXT MENU. Pharos builds it in `menuNeedsUpdate` when the click
//     arrives, so nothing of it exists in the tree beforehand. This posts a
//     real right-click and then dumps what the app just built — which is the
//     only way to see a menu whose items depend on the row.
//
// Clicks are real CGEvents to the HID tap, with `.mouseEventClickState` set per
// click. System Events' `click at {x,y}` does NOT drive a custom NSView's
// mouseDown/mouseUp, and keystrokes do not land on a binary launched by exec
// rather than LaunchServices (tasks/lessons.md).
//
// The default click point is 60pt in from the row's leading edge, past the
// disclosure triangle — clicking the triangle toggles the row instead of
// selecting it. `--offset` moves it for a deeper level of nesting.
//
// Never kill the driven process by name; the caller owns its pid.

import AppKit
import ApplicationServices

// MARK: - Arguments

let args = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    FileHandle.standardError.write(
        "usage: ax-tree <pid> rows|expand|collapse|click|rightclick|doubleclick [<row-text>] [--offset N]\n"
            .data(using: .utf8)!)
    exit(2)
}
guard args.count >= 2, let pid = pid_t(args[0]) else { usage() }
let command = args[1]
let rowText = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : nil
var clickOffset: CGFloat = 60
if let i = args.firstIndex(of: "--offset"), i + 1 < args.count, let v = Double(args[i + 1]) {
    clickOffset = CGFloat(v)
}

let app = AXUIElementCreateApplication(pid)

// MARK: - Accessibility helpers

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func role(_ element: AXUIElement) -> String {
    (attr(element, kAXRoleAttribute) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func windows() -> [AXUIElement] {
    (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

/// Every string a row displays, in tree order. A Pharos row is a custom cell
/// view, so its name, subtitle and badge are three separate AXStaticText
/// children rather than the row's own title.
func texts(_ element: AXUIElement) -> [String] {
    var out: [String] = []
    if role(element) == "AXStaticText" {
        for key in [kAXValueAttribute, kAXTitleAttribute] {
            if let s = attr(element, key) as? String, !s.isEmpty, !out.contains(s) { out.append(s) }
        }
    }
    for child in children(element) { out += texts(child) }
    return out
}

func frame(_ element: AXUIElement) -> CGRect {
    guard let p = attr(element, "AXPosition"), let s = attr(element, "AXSize") else { return .zero }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func collect(_ element: AXUIElement, role wanted: String, into out: inout [AXUIElement]) {
    if role(element) == wanted { out.append(element) }
    for child in children(element) { collect(child, role: wanted, into: &out) }
}

func allRows() -> [AXUIElement] {
    var out: [AXUIElement] = []
    for window in windows() { collect(window, role: "AXRow", into: &out) }
    return out
}

/// The row holding `needle`. An EXACT text match wins over a substring, for the
/// same reason ax-do's menu verb prefers one: a tree of `dns_log`,
/// `dns_log_2013` and `dns_log_20130101` has no other way to name the root.
func findRow(_ needle: String) -> AXUIElement? {
    let rows = allRows()
    if let exact = rows.first(where: { texts($0).contains(needle) }) { return exact }
    return rows.first { texts($0).contains { $0.contains(needle) } }
}

func requireRow(_ needle: String?) -> AXUIElement {
    guard let needle else { usage() }
    guard let row = findRow(needle) else {
        FileHandle.standardError.write("no row matches \(needle)\n".data(using: .utf8)!)
        exit(5)
    }
    return row
}

// MARK: - Actions

func setDisclosing(_ row: AXUIElement, _ open: Bool) {
    let err = AXUIElementSetAttributeValue(
        row, "AXDisclosing" as CFString, (open ? kCFBooleanTrue : kCFBooleanFalse)!)
    if err != .success {
        FileHandle.standardError.write("disclose failed: \(err.rawValue)\n".data(using: .utf8)!)
        exit(6)
    }
}

func postClick(at point: CGPoint, right: Bool, clicks: Int64) {
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let button: CGMouseButton = right ? .right : .left

    // Move first: an NSView's tracking areas and the menu's own hit test both
    // read the cursor position, not the event's.
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)

    for n in 1...clicks {
        for type in [down, up] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button)
            // The click count is what makes the second pair a DOUBLE-click
            // rather than two single ones. Without it a double-click action
            // never fires.
            event?.setIntegerValueField(.mouseEventClickState, value: n)
            event?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        usleep(40_000)
    }
}

/// Print every menu the app is currently showing, once each.
///
/// A menu is reachable both through the window that opened it and through
/// AXFocusedUIElement, so the roots are walked and then de-duplicated by
/// element identity — otherwise every item prints twice.
func dumpOpenMenus() {
    var roots = windows()
    if let focused = attr(app, "AXFocusedUIElement") { roots.append(focused as! AXUIElement) }

    var menus: [AXUIElement] = []
    for root in roots {
        var found: [AXUIElement] = []
        collect(root, role: "AXMenu", into: &found)
        // Only the ROOT menus. A submenu is an AXMenu too, and it is printed
        // under the item that owns it — collecting it here as well would list
        // the limit presets a second time, detached from their item.
        for menu in found where !isSubmenu(menu) && !menus.contains(where: { CFEqual($0, menu) }) {
            menus.append(menu)
        }
    }
    guard !menus.isEmpty else {
        FileHandle.standardError.write("no menu opened\n".data(using: .utf8)!)
        exit(6)
    }
    for menu in menus { printItems(of: menu, indent: 0) }
}

/// Whether this menu hangs off a menu ITEM, i.e. is a submenu.
func isSubmenu(_ menu: AXUIElement) -> Bool {
    guard let parent = attr(menu, kAXParentAttribute) else { return false }
    return role(parent as! AXUIElement) == "AXMenuItem"
}

func printItems(of menu: AXUIElement, indent: Int) {
    for item in children(menu) where role(item) == "AXMenuItem" {
        let title = (attr(item, kAXTitleAttribute) as? String) ?? ""
        let enabled = (attr(item, kAXEnabledAttribute) as? Bool) ?? true
        let pad = String(repeating: "  ", count: indent)
        print(pad + (title.isEmpty ? "—— separator ——" : title) + (enabled || title.isEmpty ? "" : "  [disabled]"))
        // A submenu ("View Contents (Limit…)") is an AXMenu child of its item.
        for sub in children(item) where role(sub) == "AXMenu" {
            printItems(of: sub, indent: indent + 1)
        }
    }
}

// MARK: - Commands

switch command {
case "rows":
    let rows = allRows()
    if rows.isEmpty {
        FileHandle.standardError.write("no rows: is the outline on screen?\n".data(using: .utf8)!)
        exit(5)
    }
    for row in rows {
        let f = frame(row)
        print("\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))  \(texts(row))")
    }

case "expand", "collapse":
    let row = requireRow(rowText)
    let open = command == "expand"
    setDisclosing(row, open)
    print("\(open ? "expanded" : "collapsed") \(rowText!)")

case "click", "rightclick", "doubleclick":
    let row = requireRow(rowText)
    let f = frame(row)
    let point = CGPoint(x: f.minX + clickOffset, y: f.midY)
    postClick(at: point, right: command == "rightclick", clicks: command == "doubleclick" ? 2 : 1)
    usleep(900_000)  // let the menu build, or the sheet present
    if command == "rightclick" {
        dumpOpenMenus()
    } else {
        print("\(command) on \(rowText!) at \(Int(point.x)),\(Int(point.y))")
    }

default:
    usage()
}
