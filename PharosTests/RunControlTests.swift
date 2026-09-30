// Standalone test runner for RunControl — the toolbar Run | Cancel transport
// control. Real AppKit: the control is hosted in a window ordered front at
// (-20000, -20000), so it lays out and draws like the real one (a never-shown
// window leaves segmented controls unrendered). The glass platter is drawn by
// the window server and never lands in a capture; this checks the glyphs.
// Compiled by scripts/test-run-control.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

/// Opaque pixels, and those close to the accent colour, in the control's
/// own rendering.
private func pixels(_ control: NSView) -> (opaque: Int, accent: Int) {
    control.display()
    guard let rep = control.bitmapImageRepForCachingDisplay(in: control.bounds) else { return (0, 0) }
    control.cacheDisplay(in: control.bounds, to: rep)
    let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
    var opaque = 0, near = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { continue }
            opaque += 1
            let d = abs(c.redComponent - accent.redComponent) + abs(c.greenComponent - accent.greenComponent)
                + abs(c.blueComponent - accent.blueComponent)
            if d < 0.35 { near += 1 }
        }
    }
    return (opaque, near)
}

func runTests() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let control = RunControl(frame: .zero)
    control.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(control)
    NSLayoutConstraint.activate([
        control.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
        control.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
    ])
    window.orderFrontRegardless()
    settle()

    // MARK: idle
    control.update(canRun: true, runningCount: 0)
    settle()
    expectEqual(control.segmentCount, 2, "two segments: Run and Cancel")
    expectEqual(control.isEnabled(forSegment: 0), true, "idle: Run is enabled")
    expectEqual(control.isEnabled(forSegment: 1), false, "idle: Cancel is disabled")
    expectEqual(control.image(forSegment: 1)?.isTemplate, true, "idle: Cancel shows the template glyph")
    expectEqual(control.isPulsing, false, "idle: the pulse clock is not held")
    expectEqual(control.accessibilityIdentifier(), "toolbar.runControl", "AX identifier")
    let idle = pixels(control)
    // Prove the capture sees the glyphs before asserting on colour
    // (tasks/lessons.md, "Glass and bezels do not land in an offscreen render").
    expectTrue(idle.opaque > 40, "the capture sees the two glyphs (\(idle.opaque) opaque px)")
    expectTrue(idle.accent < 5, "idle: no accent pixels (\(idle.accent))")

    control.update(canRun: false, runningCount: 0)
    expectEqual(control.isEnabled(forSegment: 0), false, "no connection: Run is disabled")

    // MARK: one running
    control.update(canRun: true, runningCount: 1)
    settle()
    expectEqual(control.isEnabled(forSegment: 0), true, "running: Run stays enabled")
    expectEqual(control.isEnabled(forSegment: 1), true, "running: Cancel is enabled")
    expectEqual(control.isPulsing, true, "running: the pulse clock is held")
    expectEqual(control.image(forSegment: 1)?.isTemplate, false, "running: Cancel shows an accent glyph")
    expectEqual(control.state.cancelAction, .cancelOne, "one running: Cancel stops it")
    expectEqual(control.image(forSegment: 1)?.accessibilityDescription, "Cancel Query", "one running: AX label")
    let running = pixels(control)
    expectTrue(running.accent > idle.accent + 10, "running: the Cancel glyph is accent-coloured (\(running.accent) px)")

    // The pulse steps the image, and a step change swaps it.
    let stepBefore = control.state.tintStep
    PulseClock.shared.value.send(stepBefore == 0 ? 1 : 0)
    expectTrue(control.state.tintStep != stepBefore, "a new pulse value moves the tint step")

    // MARK: several running
    control.update(canRun: true, runningCount: 2)
    expectEqual(control.state.cancelAction, .showList, "two running: Cancel opens the list")
    expectEqual(control.image(forSegment: 1)?.accessibilityDescription, "Cancel 2 Queries", "two running: AX label")
    let rect = control.cancelSegmentRect
    expectTrue(rect.minX >= control.bounds.midX - 0.5 && rect.maxX <= control.bounds.maxX + 0.5,
               "the list anchors to the Cancel half")

    // MARK: presses
    var pressed: [RunControl.Segment] = []
    control.onPress = { pressed.append($0) }
    // Through accessibility — the path VoiceOver and scripts/ax-do.swift use.
    // A programmatic `selectedSegment` does not stick on a momentary control.
    let cell = (control.accessibilityChildren() as? [NSObject])?.first
    let segments = (cell?.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
    expectEqual(segments.count, 2, "AX exposes two segments")
    let labels = segments.map { ($0.value(forKey: "accessibilityLabel") as? String) ?? "" }
    expectEqual(labels, ["Run Query", "Cancel 2 Queries"], "AX segment labels")
    for segment in segments.reversed() {
        _ = segment.perform(NSSelectorFromString("accessibilityPerformPress"))
    }
    expectEqual(pressed, [.cancel, .run], "each segment reports itself")

    // MARK: back to idle
    control.update(canRun: true, runningCount: 0)
    settle()
    expectEqual(control.isPulsing, false, "idle again: the pulse clock is released")
    expectEqual(control.image(forSegment: 1)?.isTemplate, true, "idle again: the template glyph is back")
    expectEqual(control.image(forSegment: 1)?.accessibilityDescription, "Cancel Query", "idle again: AX label")
    let after = pixels(control)
    expectTrue(after.accent < 5, "idle again: no accent pixels (\(after.accent))")

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
