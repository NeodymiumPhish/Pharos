// ax-do — drive one control of a running process through the accessibility API.
//
//   swiftc -O -o /tmp/ax-do scripts/ax-do.swift
//   /tmp/ax-do <pid> list [<window-title-substring>]
//   /tmp/ax-do <pid> set   <role> <match> <value>   [<window-title-substring>]
//   /tmp/ax-do <pid> press <role> <match>           [<window-title-substring>]
//   /tmp/ax-do <pid> focus <role> <match>           [<window-title-substring>]
//
// <role> is an AX role such as AXTextField, AXSecureTextField, AXButton,
// AXPopUpButton, AXCheckBox. <match> is a case-insensitive substring tested
// against the element's title, description, placeholder, identifier and
// value, or "#N" for the N-th element of that role (0-based) in tree order.
// "list" prints every element of a form role with its matchable strings.
// Exit 5 when no element matches, 6 when the action fails.
//
// Companion to ax-walk.swift: the walker reads, this one writes. Both address
// the process by pid, never by name (tasks/lessons.md).

import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[0]) else {
    FileHandle.standardError.write("usage: ax-do <pid> list|set|press|focus ...\n".data(using: .utf8)!)
    exit(2)
}
let command = args[1]

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String {
    guard let v = attr(el, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func matchable(_ el: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXValueAttribute]
        .map { str(el, $0) }
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func collect(_ el: AXUIElement, role: String?, into acc: inout [AXUIElement], depth: Int = 0) {
    if depth > 25 { return }
    let r = str(el, kAXRoleAttribute)
    if role == nil || r == role { acc.append(el) }
    for c in children(el) { collect(c, role: role, into: &acc, depth: depth + 1) }
}

let app = AXUIElementCreateApplication(pid)
let windowFilter: String? = {
    switch command {
    case "list": return args.count > 2 ? args[2] : nil
    case "set": return args.count > 5 ? args[5] : nil
    default: return args.count > 4 ? args[4] : nil
    }
}()
var roots: [AXUIElement] = children(app).filter { str($0, kAXRoleAttribute) == "AXWindow" }
if let f = windowFilter?.lowercased() {
    roots = roots.filter { str($0, kAXTitleAttribute).lowercased().contains(f) }
}
if roots.isEmpty { roots = [app] }

func findElement(role: String, match: String) -> AXUIElement? {
    var all: [AXUIElement] = []
    for r in roots { collect(r, role: role, into: &all) }
    if match.hasPrefix("#"), let i = Int(match.dropFirst()) { return i < all.count ? all[i] : nil }
    let m = match.lowercased()
    return all.first { matchable($0).contains { $0.lowercased().contains(m) } }
}

switch command {
case "list":
    let roles = ["AXTextField", "AXSecureTextField", "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXComboBox", "AXMenuButton", "AXTextArea"]
    for r in roles {
        var all: [AXUIElement] = []
        for root in roots { collect(root, role: r, into: &all) }
        for (i, el) in all.enumerated() {
            let m = matchable(el).enumerated().filter { !$0.element.isEmpty }.map { "\(["title","desc","placeholder","id","value"][$0.offset])=\($0.element.prefix(60))" }
            print("\(r) #\(i) \(m.joined(separator: " | "))")
        }
    }
case "set":
    guard args.count >= 5 else { exit(2) }
    guard let el = findElement(role: args[2], match: args[3]) else { FileHandle.standardError.write("no match\n".data(using: .utf8)!); exit(5) }
    let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, args[4] as CFTypeRef)
    if err != .success { FileHandle.standardError.write("set failed: \(err.rawValue)\n".data(using: .utf8)!); exit(6) }
    print("set ok: \(str(el, kAXValueAttribute))")
case "press":
    guard args.count >= 4 else { exit(2) }
    guard let el = findElement(role: args[2], match: args[3]) else { FileHandle.standardError.write("no match\n".data(using: .utf8)!); exit(5) }
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    if err != .success { FileHandle.standardError.write("press failed: \(err.rawValue)\n".data(using: .utf8)!); exit(6) }
    print("press ok")
case "focus":
    guard args.count >= 4 else { exit(2) }
    guard let el = findElement(role: args[2], match: args[3]) else { FileHandle.standardError.write("no match\n".data(using: .utf8)!); exit(5) }
    let err = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if err != .success { FileHandle.standardError.write("focus failed: \(err.rawValue)\n".data(using: .utf8)!); exit(6) }
    print("focus ok")
default:
    exit(2)
}
