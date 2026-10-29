// Standalone test runner for the gantt canvas (ChartCanvas, .gantt).
// Compiled by scripts/test-gantt-canvas.sh. Needs the window server: the
// scroll test shows a borderless window at the screen origin for about a
// second, so screen and window coordinates agree for the synthetic events.
import AppKit
import SwiftUI

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// The open-ports shape: lane = ip · port, Bars by = service · data.
private func ganttData() -> (ChartData, ChartConfig) {
    let cols = [("ip", "inet"), ("port", "int4"), ("service", "text"), ("data", "text"), ("first_seen", "timestamptz"), ("last_seen", "timestamptz")]
    var rows: [[String?]] = [
        ["198.51.100.7", "80", "http", "HTTP/1.1 200 OK\nServer: nginx", "2016-01-01 00:00:00+00", "2019-06-01 00:00:00+00"],
        ["198.51.100.7", "80", "http", "HTTP/1.1 200 OK\nServer: Apache", "2020-01-01 00:00:00+00", "2023-06-01 00:00:00+00"],
        ["203.0.113.9", "22", "ssh", "SSH-2.0-OpenSSH_8.9", "2016-01-01 00:00:00+00", "2019-06-01 00:00:00+00"],
    ]
    for i in 0..<20 { rows.append(["192.0.2.\(i)", "8080", "http-alt", "banner \(i)", "2024-01-01 00:00:00+00", "2024-01-01 00:00:00+00"]) }
    let res = QueryResult(columns: cols.map { ColumnDef(name: $0.0, dataType: $0.1) },
                          rows: rows.map { $0.map { AnyCodable($0 as Any?) } }, rowCount: rows.count,
                          executionTimeMs: 0, hasMore: false, historyEntryId: nil)
    var cfg = ChartConfig(chartType: .gantt)
    cfg.setColumns([ColumnRef(index: 0, name: "ip"), ColumnRef(index: 1, name: "port")], for: .label)
    cfg.setColumns([ColumnRef(index: 2, name: "service"), ColumnRef(index: 3, name: "data")], for: .segment)
    cfg.mappings[.start] = ColumnRef(index: 4, name: "first_seen")
    cfg.mappings[.end] = ColumnRef(index: 5, name: "last_seen")
    cfg.temporalBin = .month
    return (ChartAggregator.aggregate(res, cfg), cfg)
}

private func snap(_ v: NSView) -> NSBitmapImageRep {
    let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: r)
    return r
}

private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    var n = 0
    for x in stride(from: 0, to: a.pixelsWide, by: 2) { for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
        if let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y),
           abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) > 0.2 { n += 1 }
    } }
    return n
}

/// Rows (bitmap y, top = 0) that hold bar ink in a column right of the lane labels.
private func barRows(_ rep: NSBitmapImageRep, x: Int) -> [Int] {
    (0..<rep.pixelsHigh).filter { y in
        guard let c = rep.colorAt(x: x, y: y) else { return false }
        return c.saturationComponent > 0.4 && c.alphaComponent > 0.5
    }
}

func runTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let (data, cfg) = ganttData()
    var selections: [[DrillKey]] = []
    let w: CGFloat = 600, h: CGFloat = 320
    let host = NSHostingView(rootView: ChartCanvas(data: data, config: cfg, onSelectionChanged: { selections.append($0) })
        .frame(width: w, height: h))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    win.orderFrontRegardless()
    defer { win.orderOut(nil) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))

    // Lanes: the first bar sits in the first lane, half a lane pitch below the
    // axis — not on the band edge where a categorical Y axis drew its labels.
    let before = snap(host)
    let rows = barRows(before, x: 300)
    expect(!rows.isEmpty, "top lane bar drawn (non-vacuity)")
    if let top = rows.first { expect(top > 24 && top < 60, "first bar inside the first lane (y \(top))") }

    // Scroll: wheel events over the plot move it (an overlay view that takes
    // hits would swallow them and leave the pixels unchanged).
    let pt = NSPoint(x: 400, y: 150)
    for (dx, dy) in [(-20, 0), (0, -20)] {
        for _ in 0..<6 {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)!
            cg.location = CGPoint(x: pt.x, y: NSScreen.screens[0].frame.maxY - pt.y)
            if let ev = NSEvent(cgEvent: cg), let v = host.hitTest(ev.locationInWindow) { v.scrollWheel(with: ev) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    expect(changedPixels(before, snap(host)) > 100, "wheel scrolls the plot through the gantt gestures")

    // Click the top lane's bar: selects lane AND segment (4 keys).
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 300, y: 280), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        win.sendEvent(e)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let names = selections.last?.flatMap(\.columnRefs).map(\.name) ?? []
    expect(names == ["ip", "port", "service", "data"], "click a bar after scrolling selects its lane and segment (\(names))")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
