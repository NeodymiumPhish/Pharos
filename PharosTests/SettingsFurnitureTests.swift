// Standalone tests for the Settings furniture kit under
// Pharos/Settings/Furniture. Compiled with the implementation by
// scripts/test-settings-furniture.sh.
//
// Everything here is MEASURED: rows are laid out in a hosted window and their
// frames read back, and the group box and badge are rendered offscreen into a
// bitmap so the colours actually painted are compared with the colours the
// metrics promise. Two hazards this suite is written around (see
// tasks/lessons.md): an NSWindow GROWS to fit content rather than compressing
// it, so every fixture is hosted in a plain root view with a REQUIRED width;
// and a bitmap rep must be retained while its pixels are read.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectNear(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.5, _ name: String) {
    if abs(actual - expected) <= tolerance { print("PASS \(name) (\(actual))") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ±\(tolerance)\n  actual:   \(actual)")
    }
}

// MARK: - Hosting

private let hostWidth: CGFloat = 560

/// A never-shown window holding a root view of a REQUIRED width. The window
/// gives the layout pass a real backing; the root's width constraint is what
/// makes compression actually happen (a window would widen instead).
private final class Host {
    let window: NSWindow
    let root: NSView

    init(width: CGFloat = hostWidth, height: CGFloat = 400) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
        ])
    }

    /// Pins `view` to the root's leading, trailing and top; height is its own.
    func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            root.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor),
        ])
        layout()
    }

    /// Two passes: `SettingsRow.layout()` feeds the labels their width during
    /// the first, which changes their intrinsic height for the second.
    func layout() {
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
    }
}

private func frame(of view: NSView, in ancestor: NSView) -> NSRect {
    view.convert(view.bounds, to: ancestor)
}

/// Auto Layout positions a view's ALIGNMENT RECT, and a label's frame carries
/// 2pt of padding each side of its glyphs (`alignmentRectInsets` left/right =
/// 2), so the text edge a reader sees is the alignment rect's edge.
private func textEdge(of label: NSTextField, in ancestor: NSView) -> CGFloat {
    label.alignmentRect(forFrame: frame(of: label, in: ancestor)).minX
}

// MARK: - Offscreen rendering

private final class Rendered {
    /// Retained on purpose: the pixels belong to the rep.
    let rep: NSBitmapImageRep
    /// Pixels per point. `bitmapImageRepForCachingDisplay` follows the main
    /// display's scale even for a view in no window, so on a Retina Mac the
    /// rep is 2x and a POINT coordinate has to be scaled to reach its pixel.
    let scale: Int
    init(rep: NSBitmapImageRep, pointWidth: CGFloat) {
        self.rep = rep
        scale = max(1, Int((CGFloat(rep.pixelsWide) / pointWidth).rounded()))
    }

    /// The pixel at a POINT coordinate, top-left origin as `colorAt` counts.
    func pixel(_ x: Int, _ y: Int) -> NSColor? {
        rep.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB)
    }
}

/// Renders `view` at its current bounds under `appearance`.
private func render(_ view: NSView, appearance: NSAppearance) -> Rendered? {
    view.appearance = appearance
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    appearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    return Rendered(rep: rep, pointWidth: view.bounds.width)
}

private func luminance(_ c: NSColor) -> CGFloat {
    let s = c.usingColorSpace(.sRGB) ?? c
    return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
}

private func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X a=%.2f",
                  Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)),
                  Int(round(s.blueComponent * 255)), s.alphaComponent)
}

private func channelsWithin(_ a: NSColor, _ b: NSColor, _ tolerance: CGFloat) -> Bool {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) <= tolerance
        && abs(a.greenComponent - b.greenComponent) <= tolerance
        && abs(a.blueComponent - b.blueComponent) <= tolerance
}

/// A one-row group box laid out at 300×80 in a plain container (no window,
/// so the rep is 1x and pixel coordinates are points).
private func plateFixture() -> (container: NSView, box: SettingsGroupBox) {
    let row = SettingsRow(title: "Plate", control: nil)
    let box = SettingsGroupBox(title: "Plate", rows: [row])
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    container.addSubview(box)
    NSLayoutConstraint.activate([
        box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        box.topAnchor.constraint(equalTo: container.topAnchor),
        box.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    return (container, box)
}

private struct PlateSample {
    let plate: NSColor
    let border: NSColor
    let expectedPlate: NSColor
    let expectedSurface: NSColor
}

private func samplePlate(appearance: NSAppearance, label: String) -> PlateSample? {
    let fixture = plateFixture()
    let box = fixture.box
    guard let rendered = render(box, appearance: appearance) else {
        failures += 1; print("FAIL \(label): could not render the group box"); return nil
    }
    let w = rendered.rep.pixelsWide, h = rendered.rep.pixelsHigh, s = rendered.scale
    expectEqual(NSSize(width: w, height: h), NSSize(width: 300 * s, height: 80 * s),
                "\(label): the rep covers the 300×80 box at \(s)x")
    guard let plate = rendered.pixel(150, 40), let border = rendered.pixel(0, 40) else {
        failures += 1; print("FAIL \(label): could not read pixels"); return nil
    }
    var expectedPlate = NSColor.black, expectedSurface = NSColor.black
    appearance.performAsCurrentDrawingAppearance {
        expectedPlate = SettingsMetrics.plateColor.usingColorSpace(.sRGB)!
        expectedSurface = SettingsMetrics.paneSurfaceColor.usingColorSpace(.sRGB)!
    }
    print("  \(label): plate px \(hex(plate)) lum \(String(format: "%.3f", luminance(plate)))"
          + " | expected plate \(hex(expectedPlate))"
          + " | surface \(hex(expectedSurface)) lum \(String(format: "%.3f", luminance(expectedSurface)))"
          + " | border px \(hex(border)) lum \(String(format: "%.3f", luminance(border)))")
    return PlateSample(plate: plate, border: border, expectedPlate: expectedPlate, expectedSurface: expectedSurface)
}

// MARK: - Tests

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // MARK: 1. A plain row: height, control edge, title edge

    do {
        let host = Host()
        let row = SettingsRow(title: "Show line numbers", control: SettingsControlFactory.toggle())
        host.mount(row)
        expectTrue((40...44).contains(Int(row.frame.height.rounded())),
                   "a short titled row is 40–44 tall (\(row.frame.height))")
        expectNear(row.control!.frame.maxX, hostWidth - SettingsMetrics.rowInsetH,
                   "the control ends rowInsetH from the trailing edge")
        expectNear(textEdge(of: row.titleLabel, in: row), SettingsMetrics.rowInsetH,
                   "with no icon the title's text edge is at rowInsetH")
        expectNear(row.titleLabel.alignmentRectInsets.left, 2, "(a label's frame sits 2pt outside its text)")
        expectTrue(row.captionLabel.isHidden, "no caption → the caption label is hidden")
    }

    do {
        let host = Host()
        let icon = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!
        let row = SettingsRow(icon: icon, title: "Appearance", control: SettingsControlFactory.popup(titles: ["Auto"]))
        host.mount(row)
        expectNear(textEdge(of: row.titleLabel, in: row),
                   SettingsMetrics.rowInsetH + SettingsMetrics.rowIconSize + SettingsMetrics.iconTextGap,
                   "with an icon the title's text edge is past the icon and its gap")
        expectNear(row.iconView!.frame.minX, SettingsMetrics.rowInsetH, "the icon starts at rowInsetH")
        expectTrue(row.showsIcon, "showsIcon reads true")
        expectNear(row.iconView!.frame.width, SettingsMetrics.rowIconSize, "the icon view is rowIconSize wide")
    }

    // MARK: 2. A long caption wraps instead of widening the box

    do {
        let host = Host()
        let caption = String(repeating: "Explains what the setting does and why you might want it. ", count: 6)
        expectTrue(caption.count >= 320, "the fixture caption is at least 320 characters (\(caption.count))")
        let row = SettingsRow(title: "Confirm destructive statements", caption: caption,
                              control: SettingsControlFactory.toggle())
        let box = SettingsGroupBox(title: nil, rows: [row])
        host.mount(box)
        let captionH = row.captionLabel.frame.height, titleH = row.titleLabel.frame.height
        expectTrue(captionH > 1.8 * titleH,
                   "the caption wrapped: \(captionH) tall against a \(titleH) title")
        expectTrue(box.fittingSize.width <= hostWidth + 0.5,
                   "the caption did not widen the box (fittingSize.width \(box.fittingSize.width))")
        expectNear(row.control!.frame.maxX, hostWidth - SettingsMetrics.rowInsetH,
                   "and the control is still on the trailing edge")
        expectTrue(row.frame.height > SettingsMetrics.rowMinHeight,
                   "the row grew to hold the caption (\(row.frame.height))")
    }

    // MARK: 3. Group box rows span and abut

    do {
        let host = Host()
        let rows = (1...3).map { SettingsRow(title: "Row \($0)", control: SettingsControlFactory.toggle()) }
        let box = SettingsGroupBox(title: "Three", rows: rows)
        host.mount(box)
        expectEqual(box.rows.count, 3, "rows reads back three")
        expectTrue(rows.allSatisfy { abs($0.frame.width - hostWidth) < 0.5 },
                   "every row is the box's width (\(rows.map { Int($0.frame.width) }))")
        let r1 = frame(of: rows[0], in: box), r2 = frame(of: rows[1], in: box)
        expectNear(r2.minY, r1.maxY, "row 2 starts where row 1 ends (flipped, no spacing)")
        expectEqual(box.accessibilityLabel(), "Three", "the AX label is the title")
        expectEqual(box.accessibilityRole(), .group, "the AX role is group")
        expectNear(box.separatorLeadingInset, SettingsMetrics.rowInsetH, "no icons → separators start at rowInsetH")
    }

    do {
        let icon = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!
        let box = SettingsGroupBox(title: nil, rows: [SettingsRow(icon: icon, title: "A", control: nil)])
        expectNear(box.separatorLeadingInset,
                   SettingsMetrics.rowInsetH + SettingsMetrics.rowIconSize + SettingsMetrics.iconTextGap,
                   "an icon row → separators start at the text edge")
    }

    // MARK: 4. Section header identifier

    do {
        let header = SettingsSectionHeader.make("Query Library")
        expectEqual(header.accessibilityIdentifier(), "settings.section.query-library", "header slug")
        expectEqual(SettingsSectionHeader.make("SSH / Tunnels (beta)").accessibilityIdentifier(),
                    "settings.section.ssh-tunnels-beta", "runs of punctuation fold to one dash, edges trimmed")
        expectTrue(header.font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "header is bold")
    }

    // MARK: 5. Footer buttons trail

    do {
        let host = Host()
        let a = SettingsControlFactory.actionButton(title: "Add…")
        let b = SettingsControlFactory.actionButton(title: "Reset to Defaults", destructive: true)
        let footer = SettingsFooterButtonRow(buttons: [a, b])
        host.mount(footer)
        expectNear(frame(of: b, in: footer).maxX, hostWidth, "the last button ends at the trailing edge")
        expectTrue(frame(of: a, in: footer).minX > hostWidth / 2,
                   "the first button sits in the trailing half (minX \(frame(of: a, in: footer).minX))")
        expectTrue(b.hasDestructiveAction, "destructive → hasDestructiveAction")
    }

    // MARK: 6. Offscreen pixels: plate, surface, border, both appearances

    var lightPlate: NSColor?, darkPlate: NSColor?
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        guard let appearance = NSAppearance(named: appearanceName) else { continue }
        guard let s = samplePlate(appearance: appearance, label: name) else { continue }
        expectTrue(channelsWithin(s.plate, s.expectedPlate, 2.0 / 255),
                   "\(name): the plate pixel is SettingsMetrics.plateColor (\(hex(s.plate)) vs \(hex(s.expectedPlate)))")
        let surfaceDelta = abs(luminance(s.plate) - luminance(s.expectedSurface))
        expectTrue(surfaceDelta >= 0.03,
                   "\(name): the plate stands off the pane surface by luminance \(String(format: "%.3f", surfaceDelta)) ≥ 0.03")
        let borderDelta = abs(luminance(s.border) - luminance(s.plate))
        expectTrue(borderDelta >= 0.03,
                   "\(name): border ink at (0,40) differs from the plate by luminance \(String(format: "%.3f", borderDelta)) ≥ 0.03")
        if name == "light" { lightPlate = s.plate } else { darkPlate = s.plate }
    }
    if let lightPlate, let darkPlate {
        expectTrue(!channelsWithin(lightPlate, darkPlate, 2.0 / 255),
                   "the light and dark plate pixels differ (\(hex(lightPlate)) vs \(hex(darkPlate))) — no frozen colour")
    } else {
        failures += 1; print("FAIL both appearances must render")
    }

    // MARK: 7. Symbol badge pixels

    do {
        let badge = SettingsSymbolBadge(symbolName: "gearshape", tint: .systemBlue)
        badge.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        if let rendered = render(badge, appearance: NSAppearance(named: .aqua)!) {
            expectEqual(rendered.rep.pixelsWide, 20 * rendered.scale, "the badge rep covers 20pt at \(rendered.scale)x")
            let corner = rendered.rep.colorAt(x: 0, y: 0)
            expectTrue((corner?.alphaComponent ?? 1) < 0.5,
                       "the badge's corner pixel is transparent (alpha \(corner?.alphaComponent ?? -1))")
            if let body = rendered.pixel(3, 10) {
                expectTrue(body.blueComponent > body.redComponent && body.alphaComponent > 0.9,
                           "the badge body is tinted blue (\(hex(body)))")
            } else { failures += 1; print("FAIL could not read the badge body pixel") }
            // Non-vacuity: the symbol landed. Something near the centre is
            // much lighter than the tint.
            var lightest: CGFloat = 0
            for x in 6...14 { for y in 6...14 {
                if let p = rendered.pixel(x, y) { lightest = max(lightest, luminance(p)) }
            } }
            expectTrue(lightest > 0.6, "white symbol ink is present near the centre (max lum \(String(format: "%.2f", lightest)))")
        } else { failures += 1; print("FAIL could not render the badge") }
        expectEqual(badge.intrinsicContentSize, NSSize(width: 20, height: 20), "badge intrinsic size is size×size")
    }

    // MARK: 8. isEnabled

    do {
        let row = SettingsRow(title: "Auto-commit", caption: "Commit each statement", control: SettingsControlFactory.toggle())
        row.isEnabled = false
        expectEqual((row.control as! NSSwitch).isEnabled, false, "disabling the row disables its switch")
        expectTrue(row.titleLabel.textColor != NSColor.labelColor, "and dims the title (\(row.titleLabel.textColor!))")
        expectTrue(row.captionLabel.textColor != NSColor.secondaryLabelColor, "and the caption")
        row.isEnabled = true
        expectEqual((row.control as! NSSwitch).isEnabled, true, "re-enabling restores the switch")
        expectTrue(row.titleLabel.textColor == NSColor.labelColor, "and the title colour")

        let custom = NSView()
        let customRow = SettingsRow(title: "Palette", control: custom, placement: .below)
        customRow.isEnabled = false
        expectNear(custom.alphaValue, 0.5, tolerance: 0.01, "a non-NSControl control dims by alpha")
    }

    // MARK: 9. caption is settable

    do {
        let host = Host()
        let row = SettingsRow(title: "Timeout", control: SettingsControlFactory.numberField(range: 1...600))
        host.mount(row)
        let singleLine = row.frame.height
        row.caption = "reason"
        host.layout()
        expectTrue(!row.captionLabel.isHidden, "setting a caption unhides the label")
        expectEqual(row.captionLabel.stringValue, "reason", "and shows the text")
        expectTrue(row.frame.height > singleLine, "the row grew (\(singleLine) → \(row.frame.height))")
        expectEqual(row.control?.accessibilityHelp(), "reason", "the control's AX help follows the caption")
        row.caption = ""
        host.layout()
        expectTrue(row.captionLabel.isHidden, "an empty caption hides it again")
        expectNear(row.frame.height, singleLine, "and the row closes up")
    }

    // MARK: 10. Control factory

    do {
        let field = SettingsControlFactory.numberField(range: 1...10)
        let formatter = field.formatter as? NumberFormatter
        expectEqual(formatter?.maximum, NSNumber(value: 10), "numberField formatter maximum")
        expectEqual(formatter?.minimum, NSNumber(value: 1), "numberField formatter minimum")
        expectEqual(formatter?.allowsFloats, false, "integers only")
        expectEqual(field.translatesAutoresizingMaskIntoConstraints, false, "factory views use Auto Layout")

        let group = SettingsControlFactory.stepperGroup(range: 5...120, unit: "s")
        expectEqual(group.stepper.maxValue, 120, "stepper maxValue is the upper bound")
        expectEqual(group.stepper.minValue, 5, "stepper minValue is the lower bound")
        expectEqual(group.stepper.valueWraps, false, "stepper does not wrap")
        expectEqual((group.field.formatter as? NumberFormatter)?.maximum, NSNumber(value: 120), "field bound matches")

        let popup = SettingsControlFactory.popup(titles: ["A", "B"])
        expectEqual(popup.numberOfItems, 2, "popup carries its titles")
        expectEqual(popup.pullsDown, false, "popup is not a pull-down")

        let slider = SettingsControlFactory.slider(range: 0.5...2)
        expectEqual(slider.maxValue, 2, "slider max")
        expectTrue(slider.isContinuous, "slider is continuous")

        let seg = SettingsControlFactory.segmented(labels: ["Auto", "Light", "Dark"])
        expectEqual(seg.segmentCount, 3, "segmented count")
        expectEqual(seg.trackingMode, .selectOne, "segmented selects one")

        let chooser = SettingsControlFactory.pathChooser(directories: true)
        expectEqual(chooser.label.lineBreakMode, .byTruncatingMiddle, "path label truncates in the middle")
        expectEqual(chooser.button.title, "Choose…", "chooser button title")

        let toggle = SettingsControlFactory.toggle()
        expectEqual(toggle.controlSize, .regular, "toggle is regular size")
    }

    // MARK: 11. Scroll wrapper

    do {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(equalToConstant: 900).isActive = true
        let scroll = SettingsFormScroll.make(content: content)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        let document = scroll.documentView!
        let clipWidth = scroll.contentView.frame.width
        expectNear(document.frame.width, clipWidth, "document width == clip width (\(clipWidth))")
        expectTrue(clipWidth >= 484 && clipWidth <= 500,
                   "the clip is the container's width less at most a legacy scroller (\(clipWidth))")
        expectNear(document.frame.height, 900, "document height follows the content")
        expectEqual(scroll.drawsBackground, false, "the scroll view is transparent")
        expectEqual(scroll.hasHorizontalScroller, false, "no horizontal scroller")
        expectTrue(document is SettingsFormDocumentView && document.isFlipped, "the document is flipped")

        let pane = SettingsFormScroll.makePane(sections: [
            SettingsSectionHeader.make("General"),
            SettingsGroupBox(title: "General", rows: [SettingsRow(title: "A", control: SettingsControlFactory.toggle())]),
        ])
        let paneHost = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        paneHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            pane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
        ])
        paneHost.layoutSubtreeIfNeeded()
        paneHost.layoutSubtreeIfNeeded()
        let stack = pane.documentView!.subviews.first as! NSStackView
        let box = stack.arrangedSubviews[1]
        expectNear(box.frame.minX, SettingsMetrics.paneInsetH, "makePane insets the box by paneInsetH")
        expectNear(box.frame.width, pane.contentView.frame.width - 2 * SettingsMetrics.paneInsetH,
                   "and the box spans the padded width")
    }

    // MARK: 12. Accessibility wiring

    do {
        let row = SettingsRow(title: "Font size", caption: "Points", control: SettingsControlFactory.numberField(range: 8...32))
        expectTrue(row.control?.accessibilityTitleUIElement() as AnyObject? === row.titleLabel,
                   "the control's AX title element is the title label")
        row.setControlIdentifier("settings.x.y")
        expectEqual(row.control?.accessibilityIdentifier(), "settings.x.y", "setControlIdentifier reads back")
        expectEqual(row.isAccessibilityElement(), false, "the row itself is not an AX element")
        expectEqual(row.control?.accessibilityHelp(), "Points", "the caption is the control's AX help")
    }

    // MARK: 13. Empty row and info button

    do {
        let host = Host()
        let empty = SettingsEmptyRow()
        host.mount(empty)
        expectNear(empty.frame.height, SettingsMetrics.rowMinHeight, "the empty row is rowMinHeight tall")
        expectNear(frame(of: empty.label, in: empty).midX, hostWidth / 2, tolerance: 1, "its label is centred")

        let info = SettingsInfoButton(help: "Why")
        expectEqual(info.accessibilityLabel(), "More Information", "info button AX label")
        expectEqual(info.accessibilityHelp(), "Why", "info button AX help")
        expectEqual(info.isBordered, false, "info button is borderless")
    }

    // MARK: 14. The appearance tile picker

    do {
        let tiles: [SettingsTilePicker.Tile] = [
            .init(title: "System",
                  image: SettingsThemeThumbnail.image(.system, size: SettingsTilePicker.tileSize)),
            .init(title: "Light",
                  image: SettingsThemeThumbnail.image(.light, size: SettingsTilePicker.tileSize)),
            .init(title: "Dark",
                  image: SettingsThemeThumbnail.image(.dark, size: SettingsTilePicker.tileSize)),
        ]
        let picker = SettingsTilePicker(tiles: tiles, selectedIndex: 1)
        picker.frame = NSRect(origin: .zero, size: picker.intrinsicContentSize)

        // Geometry: three tiles in a row, left to right, none overlapping, and
        // every one inside the control.
        expectTrue(picker.tileRect(0).maxX <= picker.tileRect(1).minX, "tile 0 is left of tile 1")
        expectTrue(picker.tileRect(1).maxX <= picker.tileRect(2).minX, "tile 1 is left of tile 2")
        expectTrue(picker.tileRect(2).maxX <= picker.bounds.maxX, "the last tile is inside the control")
        // The caption is part of the target, so the hit box is taller than the
        // picture — otherwise the word under a tile would not be clickable.
        expectTrue(picker.hitRect(0).height > picker.tileRect(0).height,
                   "the hit box includes the caption")

        // The light and dark tiles are PICTURES of two appearances, so they
        // must differ from each other no matter which appearance the window is
        // in. A dynamic system colour here would make them identical, which is
        // exactly the mistake this checks for.
        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: name),
                  let r = render(picker, appearance: appearance) else {
                failures += 1
                print("FAIL could not render the tile picker in \(label)")
                continue
            }
            let lightTile = picker.tileRect(1)
            let darkTile = picker.tileRect(2)
            // The middle of each picture's window area, clear of the ring.
            guard let onLight = r.pixel(Int(lightTile.midX), Int(lightTile.midY)),
                  let onDark = r.pixel(Int(darkTile.midX), Int(darkTile.midY)) else {
                failures += 1
                print("FAIL could not sample the tiles in \(label)")
                continue
            }
            let gap = luminance(onLight) - luminance(onDark)
            expectTrue(gap > 0.3,
                       "\(label): the Light tile is lighter than the Dark tile "
                           + "(\(hex(onLight)) vs \(hex(onDark)), gap \(String(format: "%.2f", gap)))")

            // The selection ring is on the chosen tile and not on the others.
            // Sampled just outside the picture's left edge, where only a ring
            // paints.
            let ringX = Int(lightTile.minX) - 2
            let bareX = Int(darkTile.minX) - 2
            if let ringPixel = r.pixel(ringX, Int(lightTile.midY)),
               let barePixel = r.pixel(bareX, Int(darkTile.midY)) {
                let delta = abs(ringPixel.redComponent - barePixel.redComponent)
                    + abs(ringPixel.greenComponent - barePixel.greenComponent)
                    + abs(ringPixel.blueComponent - barePixel.blueComponent)
                expectTrue(delta > 0.15,
                           "\(label): the chosen tile is ringed and the others are not "
                               + "(\(hex(ringPixel)) vs \(hex(barePixel)))")
            }
        }

        // The child elements must be the SAME objects from one call to the
        // next. They are not retained by the accessibility server, so a fresh
        // array per call is released as soon as the call returns and the
        // server reports a radio group with no children at all — right role,
        // nothing inside. Caught live on 2026-09-20; this is the unit-level
        // shape of it.
        do {
            let host = Host()
            host.mount(picker)
            let first = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            let second = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            expectEqual(first.count, 3, "the radio group has one child per tile")
            expectTrue(first.count == second.count && !first.isEmpty
                        && zip(first, second).allSatisfy { $0 === $1 },
                       "the child elements are kept, not rebuilt on every query")
            expectEqual(first.first?.accessibilityRole()?.rawValue,
                        NSAccessibility.Role.radioButton.rawValue, "each child is a radio button")
            expectEqual(first.first?.accessibilityLabel(), "System", "the first child is the System tile")
        }

        // Selection moves by keyboard, and only a USER gesture writes back.
        var fired = 0
        let sink = ActionSink { fired += 1 }
        picker.target = sink
        picker.action = #selector(ActionSink.fire)
        picker.selectedIndex = 0
        expectEqual(fired, 0, "setting selectedIndex does not fire the action")
    }

    // MARK: 15. The search index

    do {
        func item(_ id: String, _ title: String, _ caption: String? = nil) -> SettingsItem {
            SettingsItem(id: id, title: title, caption: caption,
                         kind: .toggle(SettingsBinding(get: { false }, set: { _ in })))
        }
        let appearance = SettingsSearchIndex.entries(
            for: [SettingsSection(title: "Values", items: [
                item("nullDisplay", "NULL display", "How NULL renders in the grid."),
                item("boolDisplay", "Boolean display"),
            ])],
            paneId: "appearance", paneTitle: "Appearance")
        let editor = SettingsSearchIndex.entries(
            for: [SettingsSection(title: "Typing", items: [
                item("tabWidth", "Tab width", "Spaces per tab stop."),
            ])],
            paneId: "editor", paneTitle: "Editor")
        let all = appearance + editor

        expectEqual(appearance.count, 3, "the pane itself plus one entry per row")

        // An empty query matches NOTHING — the caller reads that as "show
        // everything", so a blank field must not be an all-panes match.
        expectEqual(SettingsSearchIndex.hits(in: all, query: "").count, 0, "an empty query matches nothing")
        expectEqual(SettingsSearchIndex.hits(in: all, query: "   ").count, 0, "whitespace matches nothing")

        // A row title match names the row to reveal.
        let nullHits = SettingsSearchIndex.hits(in: all, query: "null")
        expectEqual(nullHits.count, 1, "\"null\" matches one pane")
        expectEqual(nullHits.first?.paneId, "appearance", "…the Appearance pane")
        expectEqual(nullHits.first?.itemId, "nullDisplay", "…and names the row to reveal")

        // A pane-name match reveals no row.
        let paneHits = SettingsSearchIndex.hits(in: all, query: "editor")
        expectEqual(paneHits.count, 1, "a pane name matches its pane")
        expectTrue(paneHits.first?.itemId == nil, "a pane-name match names no row")

        // A row title outranks a caption, so the hit shown is the useful one.
        let displayHits = SettingsSearchIndex.hits(in: all, query: "display")
        expectEqual(displayHits.first?.itemId, "nullDisplay",
                    "the first row whose TITLE matches wins over one whose caption does")

        // Every word must land, but they may land in different fields.
        expectEqual(SettingsSearchIndex.hits(in: all, query: "null grid").count, 1,
                    "two words, one in the title and one in the caption, still match")
        expectEqual(SettingsSearchIndex.hits(in: all, query: "null zebra").count, 0,
                    "a word that matches nothing rules the entry out")

        // Case and accents are ignored.
        expectEqual(SettingsSearchIndex.hits(in: all, query: "BOOLEAN").count, 1, "case is ignored")
        expectEqual(SettingsSearchIndex.hits(in: all, query: "édîtor").count, 1, "accents are ignored")

        // A placeholder row is not a setting and is not indexed.
        let withEmpty = SettingsSearchIndex.entries(
            for: [SettingsSection(title: nil, items: [
                SettingsItem(id: "none", title: "None", kind: .empty("No Items")),
            ])],
            paneId: "tags", paneTitle: "Tags")
        expectEqual(withEmpty.count, 1, "an empty-state row is not indexed")
    }

    // MARK: 16. The tile row fits the NARROWEST pane

    // Three tiles in a row's trailing slot is the widest control this kit
    // carries, and the detail pane can be dragged down to 520 pt
    // (`SettingsSplitViewController` sets that as the minimum). Widening the
    // tiles later would push the text column to nothing, or the tiles off the
    // plate, with nothing else to catch it.
    do {
        let narrowestPane: CGFloat = 520
        let plate = narrowestPane - SettingsMetrics.paneInsetH * 2
        let tiles: [SettingsTilePicker.Tile] = ["System", "Light", "Dark"].map {
            .init(title: $0,
                  image: SettingsThemeThumbnail.image(.light, size: SettingsTilePicker.tileSize))
        }
        let picker = SettingsTilePicker(tiles: tiles)
        let icon = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)!
        let row = SettingsRow(icon: icon, title: "Appearance",
                              caption: "System follows the Mac's own setting.",
                              control: picker)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: plate, height: 400))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let tileFrame = picker.convert(picker.bounds, to: row)
        let titleFrame = row.titleLabel.convert(row.titleLabel.bounds, to: row)
        let captionFrame = row.captionLabel.convert(row.captionLabel.bounds, to: row)

        expectTrue(tileFrame.maxX <= plate + 0.5,
                   "the tiles stay on the plate at the narrowest pane (\(tileFrame.maxX) of \(plate))")
        expectTrue(abs(tileFrame.width - picker.intrinsicContentSize.width) < 0.5,
                   "the tiles are not squashed to fit")
        expectTrue(max(titleFrame.maxX, captionFrame.maxX) <= tileFrame.minX + 0.5,
                   "the text column stays clear of the tiles")
        expectTrue(titleFrame.width > 40,
                   "the title still has room to read (\(titleFrame.width) pt)")
    }

    // MARK: 17. The ⓘ popover still holds its text after it opens

    // The popover measures its content BEFORE `show`, and AppKit lays that
    // content out again once the popover owns it. A wrapping label with only a
    // width CEILING collapsed in that second pass: the popover kept the
    // measured height and showed a few points of empty width. Measure after
    // the pass that used to break it, not before.

    do {
        let help = "Off still restores the tabs, and lets macOS place the window — "
            + "which is what you want after the displays change."
        let host = Host()
        let info = SettingsInfoButton(help: help)
        host.mount(info)
        host.window.makeKeyAndOrderFront(nil)
        info.presentHelp()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let popover = info.popover
        let content = popover?.contentViewController?.view
        let label = content?.subviews.compactMap { $0 as? NSTextField }.first
        expectTrue(popover?.isShown == true, "the ⓘ opens a popover")
        expectTrue((popover?.contentSize.width ?? 0) > 200,
                   "the popover keeps a readable width after show (\(popover?.contentSize.width ?? 0) pt)")
        expectTrue((label?.frame.width ?? 0) > 200,
                   "the help label keeps its width after show (\(label?.frame.width ?? 0) pt)")
        expectTrue((label?.frame.height ?? 0) > 20,
                   "the help wraps to more than one line (\(label?.frame.height ?? 0) pt)")
        expectEqual(label?.stringValue, help, "the popover shows the help it was given")
        popover?.performClose(nil)
        host.window.orderOut(nil)
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

/// Counts action messages, so a test can tell a user gesture from a refresh.
private final class ActionSink: NSObject {
    private let onFire: () -> Void
    init(onFire: @escaping () -> Void) { self.onFire = onFire }
    @objc func fire() { onFire() }
}
