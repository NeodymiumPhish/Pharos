// ax-walk — dump the accessibility tree of a running process as JSON.
//
// Usage:
//   swiftc -O -o /tmp/ax-walk scripts/ax-walk.swift
//   /tmp/ax-walk <pid> [--depth N] [--wait-window SECONDS] [--roles ROLE,ROLE] [--pretty] [--focused]
//
// --focused         Print only the focused element (role, title, description,
//                   placeholder, identifier, frame) as one JSON object and exit.
//
// --wait-window S   Poll the window server up to S seconds for an on-screen window
//                   owned by <pid>, then walk. Exit 3 if none appears. This is the
//                   startup check that tasks/lessons.md demands: pgrep is not one.
// --depth N         Maximum tree depth (default 12).
// --roles A,B       Emit only elements whose role is in the list (ancestors kept).
// --pretty          Indented JSON.
//
// Output: one JSON object {pid, windows:[{number,bounds,title}], tree:{...}}.
// Each tree node: role, subrole?, title?, description?, value?, identifier?,
// frame:{x,y,w,h} in screen points (top-left origin, as AX reports), children:[...].
//
// Frames come from the AX server, so they are the same numbers a later phase must
// reproduce. Never kill the walked process by name; the caller owns its pid.

import AppKit
import ApplicationServices

struct Options {
    var pid: pid_t = 0
    var depth = 12
    var waitSeconds: Double = 0
    var roles: Set<String>? = nil
    var pretty = false
    var focusedOnly = false
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first, let pid = pid_t(first) else {
        FileHandle.standardError.write("usage: ax-walk <pid> [--depth N] [--wait-window S] [--roles A,B] [--pretty]\n".data(using: .utf8)!)
        exit(2)
    }
    o.pid = pid
    args.removeFirst()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--depth": o.depth = Int(args[i + 1]) ?? o.depth; i += 2
        case "--wait-window": o.waitSeconds = Double(args[i + 1]) ?? 0; i += 2
        case "--roles": o.roles = Set(args[i + 1].split(separator: ",").map(String.init)); i += 2
        case "--pretty": o.pretty = true; i += 1
        case "--focused": o.focusedOnly = true; i += 1
        default: i += 1
        }
    }
    return o
}

func onScreenWindows(for pid: pid_t) -> [[String: Any]] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

func size(_ el: AXUIElement, _ name: String) -> CGSize? {
    guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

func scalar(_ v: AnyObject?) -> Any? {
    guard let v else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n }
    if let u = v as? URL { return u.absoluteString }
    return nil
}

func round2(_ x: CGFloat) -> Double { (Double(x) * 100).rounded() / 100 }

func walk(_ el: AXUIElement, depth: Int, opts: Options) -> [String: Any]? {
    var node: [String: Any] = [:]
    let role = (attr(el, kAXRoleAttribute) as? String) ?? "?"
    node["role"] = role
    if let s = attr(el, kAXSubroleAttribute) as? String { node["subrole"] = s }
    if let t = scalar(attr(el, kAXTitleAttribute)) { node["title"] = t }
    if let d = scalar(attr(el, kAXDescriptionAttribute)) { node["description"] = d }
    if let v = scalar(attr(el, kAXValueAttribute)) {
        if let s = v as? String { node["value"] = s.count > 200 ? String(s.prefix(200)) + "…" : s } else { node["value"] = v }
    }
    if let i = attr(el, kAXIdentifierAttribute) as? String, !i.isEmpty { node["identifier"] = i }
    if let e = attr(el, kAXEnabledAttribute) as? Bool, e == false { node["enabled"] = false }
    if let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) {
        node["frame"] = ["x": round2(p.x), "y": round2(p.y), "w": round2(s.width), "h": round2(s.height)]
    }
    var children: [[String: Any]] = []
    if depth < opts.depth, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids {
            if let child = walk(kid, depth: depth + 1, opts: opts) { children.append(child) }
        }
    }
    if !children.isEmpty { node["children"] = children }
    if let roles = opts.roles, !roles.contains(role), children.isEmpty { return nil }
    return node
}

let opts = parse()

if !AXIsProcessTrusted() {
    FileHandle.standardError.write("ax-walk: this process is not trusted for accessibility (System Settings > Privacy & Security > Accessibility)\n".data(using: .utf8)!)
    exit(4)
}

var windows = onScreenWindows(for: opts.pid)
if opts.waitSeconds > 0 {
    let deadline = Date().addingTimeInterval(opts.waitSeconds)
    while windows.isEmpty && Date() < deadline {
        usleep(200_000)
        windows = onScreenWindows(for: opts.pid)
    }
    if windows.isEmpty {
        FileHandle.standardError.write("ax-walk: no on-screen window for pid \(opts.pid) after \(opts.waitSeconds)s\n".data(using: .utf8)!)
        exit(3)
    }
}

let app = AXUIElementCreateApplication(opts.pid)

if opts.focusedOnly {
    var focused: [String: Any] = [:]
    if let el = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(el) == AXUIElementGetTypeID() {
        let e = el as! AXUIElement
        focused["role"] = (attr(e, kAXRoleAttribute) as? String) ?? "?"
        if let t = scalar(attr(e, kAXTitleAttribute)) { focused["title"] = t }
        if let d = scalar(attr(e, kAXDescriptionAttribute)) { focused["description"] = d }
        if let p = scalar(attr(e, kAXPlaceholderValueAttribute)) { focused["placeholder"] = p }
        if let i = attr(e, kAXIdentifierAttribute) as? String, !i.isEmpty { focused["identifier"] = i }
        if let v = scalar(attr(e, kAXValueAttribute)) as? String { focused["value"] = String(v.prefix(80)) }
        if let p = point(e, kAXPositionAttribute), let s = size(e, kAXSizeAttribute) {
            focused["frame"] = ["x": round2(p.x), "y": round2(p.y), "w": round2(s.width), "h": round2(s.height)]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: focused, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(0)
}

var out: [String: Any] = ["pid": Int(opts.pid)]
out["windows"] = windows.map { w -> [String: Any] in
    var d: [String: Any] = ["number": w[kCGWindowNumber as String] ?? 0]
    if let b = w[kCGWindowBounds as String] { d["bounds"] = b }
    if let t = w[kCGWindowName as String] { d["title"] = t }
    return d
}
out["tree"] = walk(app, depth: 0, opts: opts) ?? [:]

let data = try JSONSerialization.data(withJSONObject: out, options: opts.pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
