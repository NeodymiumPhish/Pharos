// Standalone test runner for ResultCellView's dimmed marks.
// Compiled with the implementation by scripts/test-result-cell-marks.sh.
//
// Every pixel assertion has a control: the same text drawn WITHOUT marks. Two
// blank images compare equal, so "the dot is faint" must be measured beside
// "the same dot, unmarked, is not".
import AppKit

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)" + (detail().isEmpty ? "" : "\n  \(detail())"))
    }
}

let font = NSFont.systemFont(ofSize: 13)

/// A cell built the way `ResultsDataSource` builds one, laid out by frame.
func makeCell(width: CGFloat = 300) -> ResultCellView {
    let cell = ResultCellView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
    cell.wantsLayer = true
    cell.appearance = NSAppearance(named: .aqua)
    let label = ResultCellLabel(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.wraps = false
    label.cell?.isScrollable = false
    label.font = font
    label.frame = NSRect(x: 0, y: 0, width: width, height: 20)
    cell.addSubview(label)
    cell.textField = label
    return cell
}

/// The label drawn alone, on transparent: every pixel's alpha is ink.
func render(_ cell: ResultCellView) -> NSBitmapImageRep {
    let label = cell.textField!
    let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds)!
    label.cacheDisplay(in: label.bounds, to: rep)
    return rep
}

/// Strongest ink in a band of columns, in POINTS from the label's left edge.
func maxAlpha(_ rep: NSBitmapImageRep, fromX: CGFloat, toX: CGFloat) -> CGFloat {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    var best: CGFloat = 0
    for x in max(0, Int(fromX * scale))..<min(rep.pixelsWide, Int(toX * scale)) {
        for y in 0..<rep.pixelsHigh {
            if let c = rep.colorAt(x: x, y: y) { best = max(best, c.alphaComponent) }
        }
    }
    return best
}

/// The first column holding any ink, in points.
func firstInkX(_ rep: NSBitmapImageRep) -> CGFloat? {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            return CGFloat(x) / scale
        }
    }
    return nil
}

func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // " abc  " with the setting on: `·abc··`, ranges [0,1] and [4,2].
    let marked = DisplayEscape.escapedCell(" abc  ", showInvisibles: true)
    expect(marked.text == "\u{B7}abc\u{B7}\u{B7}", "fixture: the renderer produced the marks")

    // The label sits 2pt in (line-fragment padding). The first dot, then "abc".
    let dotBand = (from: CGFloat(0), to: 2 + width("\u{B7}"))
    let letterBand = (from: 2 + width("\u{B7}"), to: 2 + width("\u{B7}abc"))

    // MARK: - 1. A mark is drawn fainter than the text, and the control is not

    do {
        let cell = makeCell()
        cell.normalTextColor = .labelColor
        cell.setDisplayedText(marked.text, dimmedRanges: marked.dimmedRanges)
        let rep = render(cell)
        let dot = maxAlpha(rep, fromX: dotBand.from, toX: dotBand.to)
        let letters = maxAlpha(rep, fromX: letterBand.from, toX: letterBand.to)

        let control = makeCell()
        control.normalTextColor = .labelColor
        control.setDisplayedText(marked.text)
        let controlDot = maxAlpha(render(control), fromX: dotBand.from, toX: dotBand.to)

        expect(letters > 0.7, "the letters draw at text strength", "max alpha \(letters)")
        expect(controlDot > 0.6, "control: an UNMARKED dot draws at text strength", "max alpha \(controlDot)")
        expect(dot > 0.05, "non-vacuity: the marked dot is drawn at all", "max alpha \(dot)")
        expect(dot < controlDot * 0.6, "the marked dot draws clearly fainter than the unmarked one",
               "marked \(dot), unmarked \(controlDot)")
    }

    // MARK: - 2. A type colour applied after the text keeps the marks

    do {
        // `styleCell` sets the text, THEN `normalTextColor`. The second must
        // rebuild the marks, not flatten the field to one colour.
        let cell = makeCell()
        cell.setDisplayedText(marked.text, dimmedRanges: marked.dimmedRanges)
        cell.normalTextColor = .systemBlue
        let attributed = cell.textField!.attributedStringValue
        let letterColor = attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        let markColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        expect(letterColor == .systemBlue, "the letters take the column's type colour")
        expect(markColor == .tertiaryLabelColor, "the mark stays tertiary under a type colour")
        expect(attributed.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == .tertiaryLabelColor,
               "the trailing run is marked too")
    }

    // MARK: - 3. On a selection fill the mark fades the selected colour

    do {
        let cell = makeCell()
        cell.normalTextColor = .labelColor
        cell.setDisplayedText(marked.text, dimmedRanges: marked.dimmedRanges)
        cell.backgroundStyle = .emphasized
        let attributed = cell.textField!.attributedStringValue
        let letterColor = attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        let markColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        expect(letterColor == .alternateSelectedControlTextColor, "emphasized: the letters are the selected colour")
        expect(markColor == NSColor.alternateSelectedControlTextColor
                   .withAlphaComponent(ResultCellView.selectedMarkAlpha),
               "emphasized: the mark is the selected colour, faded — tertiary grey would vanish on the fill")

        let rep = render(cell)
        let dot = maxAlpha(rep, fromX: dotBand.from, toX: dotBand.to)
        let letters = maxAlpha(rep, fromX: letterBand.from, toX: letterBand.to)
        let control = makeCell()
        control.normalTextColor = .labelColor
        control.setDisplayedText(marked.text)
        control.backgroundStyle = .emphasized
        let controlDot = maxAlpha(render(control), fromX: dotBand.from, toX: dotBand.to)
        expect(letters > 0.9 && dot > 0.05 && dot < controlDot * 0.75,
               "emphasized: pixels agree — the mark is drawn, fainter than the unmarked dot",
               "dot \(dot), unmarked \(controlDot)")

        cell.backgroundStyle = .normal
        cell.isSelected = true
        cell.selectionEmphasized = false
        let unemphasized = cell.textField!.attributedStringValue
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        expect(unemphasized == NSColor.unemphasizedSelectedTextColor
                   .withAlphaComponent(ResultCellView.selectedMarkAlpha),
               "unemphasized selection: the mark fades the unemphasized colour")
    }

    // MARK: - 4. A recycled cell cannot carry its last value's marks

    do {
        let cell = makeCell()
        cell.normalTextColor = .labelColor
        cell.setDisplayedText(marked.text, dimmedRanges: marked.dimmedRanges)
        cell.setDisplayedText("\u{B7}xyz")
        cell.isSelected = true      // any colour refresh after the reuse
        cell.isSelected = false
        expect(cell.dimmedRanges.isEmpty, "reuse: the ranges are cleared")
        let attributed = cell.textField!.attributedStringValue
        var colors = Set<NSColor>()
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        expect(colors.count == 1, "reuse: the new value draws in one colour", "colours \(colors)")

        let fresh = makeCell()
        fresh.normalTextColor = .labelColor
        fresh.setDisplayedText("\u{B7}xyz")
        expect(render(cell).tiffRepresentation == render(fresh).tiffRepresentation,
               "reuse: pixel-identical to a fresh cell showing the same value")
    }

    // MARK: - 5. The marked form keeps the label's alignment and truncation

    do {
        let numeric = DisplayEscape.escapedCell("42 ", showInvisibles: true)
        let cell = makeCell()
        cell.textField!.alignment = .right
        cell.normalTextColor = .systemBlue
        cell.setDisplayedText(numeric.text, dimmedRanges: numeric.dimmedRanges)
        let firstInk = firstInkX(render(cell)) ?? 0
        expect(firstInk > 300 - 2 - width("42\u{B7}") - 4,
               "a right-aligned (numeric) column stays right-aligned when marked", "first ink at \(firstInk)")

        let long = DisplayEscape.escapedCell(" " + String(repeating: "wide ", count: 30), showInvisibles: true)
        let narrow = makeCell(width: 120)
        narrow.normalTextColor = .labelColor
        narrow.setDisplayedText(long.text, dimmedRanges: long.dimmedRanges)
        let paragraph = narrow.textField!.attributedStringValue
            .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        expect(paragraph?.lineBreakMode == .byTruncatingTail,
               "a marked value still truncates at the tail — not wrap, not clip")
        let size = narrow.textField!.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 120, height: 1000))
        expect(size.height < 20, "a marked value stays on one line", "height \(size.height)")
    }

    // MARK: - 6. The label's AX value override is read back

    do {
        let cell = makeCell()
        let label = cell.textField as! ResultCellLabel
        // Through the selector the AX server calls, not a Swift overload pick.
        func axValue() -> String? {
            label.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
        }
        label.stringValue = "\u{B7}abc"
        expect(axValue() == "\u{B7}abc", "no override: the displayed text")
        label.accessibilityValueOverride = "space abc"
        expect(axValue() == "space abc", "override: the described text")
        label.accessibilityValueOverride = nil
        expect(axValue() == "\u{B7}abc", "override cleared: the displayed text again")
    }

    if failures == 0 {
        print("\nAll ResultCellView mark tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
