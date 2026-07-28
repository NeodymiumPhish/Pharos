// Standalone test runner for VariableValueTextView and VariableRowView — no
// Xcode project or test target involvement. Unlike the rest of PharosTests,
// this one measures real AppKit geometry (Auto Layout, hit-testing, resolved
// colours) rather than pure Swift logic, because a clean compile proved these
// views compile, not that they behave: the plan's original code shipped four
// layout/hit-testing defects invisible to the compiler and to a build log.
// Compiled with VariableRowView.swift, VariableValueTextView.swift,
// VariableSubstitutor.swift, VariableValuePreview.swift and QueryVariable.swift
// by scripts/test-variable-row-layout.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.5, _ name: String) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

// MARK: - Harness helpers

/// A borderless, never-shown window hosting `row` at a fixed width. A window
/// is required, not optional plumbing: an unhosted NSView hierarchy never runs
/// a real Auto Layout pass (constraints silently no-op and the view keeps
/// whatever frame its factory initializer gave it), so measuring a windowless
/// view would validate nothing.
private func makeHostedRow(width: CGFloat, height: CGFloat = 800) -> (window: NSWindow, container: NSView, row: VariableRowView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container
    let row = VariableRowView(frame: .zero)
    row.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        row.topAnchor.constraint(equalTo: container.topAnchor),
        row.widthAnchor.constraint(equalToConstant: width),
    ])
    container.layoutSubtreeIfNeeded()
    return (window, container, row)
}

/// The chevron is the image view nearest the trailing edge (the other image
/// view, the warning triangle, sits up near the name/type line).
private func chevron(in row: VariableRowView) -> NSImageView {
    row.subviews.compactMap { $0 as? NSImageView }.max(by: { $0.frame.minX < $1.frame.minX })!
}

private func topRightStack(in row: VariableRowView) -> NSStackView {
    row.subviews.compactMap { $0 as? NSStackView }.first!
}

/// `localPoint` is in `row`'s own bounds space (e.g. a subview's frame
/// midpoint); converted into `container`'s space for the hit test, matching
/// how a real mouse event's window-space point gets converted before
/// `hitTest` is called on the content view.
private func hitsRow(_ row: VariableRowView, in container: NSView, at localPoint: NSPoint) -> Bool {
    container.hitTest(row.convert(localPoint, to: container)) === row
}

private func hasAmbiguousLayoutRecursively(_ view: NSView) -> Bool {
    if view.hasAmbiguousLayout { return true }
    return view.subviews.contains { hasAmbiguousLayoutRecursively($0) }
}

private func colorAt(_ attrString: NSAttributedString, _ index: Int) -> NSColor {
    attrString.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor
}

// MARK: - Fixtures

private let shortName = QueryVariable(name: "id", value: "a value", type: .literal)
private let name14 = QueryVariable(name: "abcdefghijklmn", value: "x", type: .literal)          // 14 chars
private let name27 = QueryVariable(name: "abcdefghijklmnopqrstuvwxyz1", value: "x", type: .literal) // 27 chars
private let name56 = QueryVariable(name: String(repeating: "a", count: 56), value: "x", type: .literal)
private let unnamed = QueryVariable(name: "", value: "", type: .literal)
private let brokenLiteral = QueryVariable(name: "id", value: "", type: .literal) // triggers .emptyLiteral

// MARK: - Tests

/// C1 — `init(frame:textContainer:)` with a nil container leaves textStorage,
/// layoutManager and textContainer all nil; `VariableValueTextView()` must
/// build its own TextKit stack instead.
private func testValueTextViewBuildsOwnTextStack() {
    let tv = VariableValueTextView()
    tv.string = "a\tb\nc"
    expectEqual(tv.string, "a\tb\nc", "VariableValueTextView() round-trips string assignment")

    tv.string = ""
    tv.insertTab(nil)
    expectEqual(tv.string, "\t", "insertTab(nil) inserts a literal tab")
}

/// I2 — `attributedStringValue`'s own paragraph style wins over
/// `nameLabel.lineBreakMode`, so without a paragraph-level truncation setting
/// a long name wraps instead of truncating and row height grows with it.
private func testRowHeightConstantAcrossNameLength() {
    let width: CGFloat = 180
    let (_, _, row14) = makeHostedRow(width: width)
    row14.configure(with: name14, state: nil)
    row14.layoutSubtreeIfNeeded()

    let (_, _, row27) = makeHostedRow(width: width)
    row27.configure(with: name27, state: nil)
    row27.layoutSubtreeIfNeeded()

    let (_, _, row56) = makeHostedRow(width: width)
    row56.configure(with: name56, state: nil)
    row56.layoutSubtreeIfNeeded()

    expectClose(row27.frame.height, row14.frame.height, "row height: 27-char name matches 14-char name at 180pt")
    expectClose(row56.frame.height, row14.frame.height, "row height: 56-char name matches 14-char name at 180pt")
}

/// I1 — `chevronView` had default (250) horizontal content hugging while both
/// of its horizontal edges carry required constraints. Its trailing edge is
/// pinned by a required constraint either way, so `frame.maxX` alone does not
/// discriminate this bug (it is always `width - 10` regardless of hugging).
/// What actually breaks is `frame.width`: without required hugging, the view
/// absorbs all of the row's slack width (measured 530pt wide of a 600pt row)
/// and `NSImageView` centres its 8pt glyph inside that oversized frame instead
/// of pinning it to the trailing edge — so the real assertion is that the
/// frame stays glyph-sized, not that its trailing edge lands in the right
/// place (which a much wider frame would also satisfy).
private func testChevronStaysGlyphSized() {
    for width: CGFloat in [180, 300, 600] {
        let (_, _, rowShort) = makeHostedRow(width: width)
        rowShort.configure(with: shortName, state: nil)
        rowShort.layoutSubtreeIfNeeded()
        let shortChevron = chevron(in: rowShort)
        expectClose(shortChevron.frame.maxX, width - 10, "chevron maxX == width-10 at \(Int(width))pt (short value)")
        expectTrue(
            shortChevron.frame.width < 20,
            "chevron stays glyph-sized (width \(shortChevron.frame.width) < 20) at \(Int(width))pt (short value)")

        let (_, _, rowLong) = makeHostedRow(width: width)
        rowLong.configure(with: name56, state: nil)
        rowLong.layoutSubtreeIfNeeded()
        let longChevron = chevron(in: rowLong)
        expectClose(longChevron.frame.maxX, width - 10, "chevron maxX == width-10 at \(Int(width))pt (long name)")
        expectTrue(
            longChevron.frame.width < 20,
            "chevron stays glyph-sized (width \(longChevron.frame.width) < 20) at \(Int(width))pt (long name)")
    }
}

/// C2 — the four labels and two image views covered the row almost entirely
/// (name, type, caption, value, chevron), so `hitTest` returned one of them
/// instead of the row over all but three thin edge strips. Also covers the
/// `topRight` NSStackView wrapping the warning glyph and type label: making
/// only its children passthrough is not enough, because the stack view itself
/// still claims any point inside it that neither child claims (e.g. the
/// inter-item spacing) — it needs its own passthrough override too.
private func testHitTestReachesRow() {
    let (_, container, row) = makeHostedRow(width: 300)
    row.configure(with: name56, state: .init(duplication: nil, problem: .emptyLiteral))
    row.layoutSubtreeIfNeeded()

    expectTrue(
        hitsRow(row, in: container, at: NSPoint(x: row.bounds.midX, y: row.bounds.midY)),
        "hitTest at row centre returns the row")

    for subview in row.subviews {
        let mid = NSPoint(x: subview.frame.midX, y: subview.frame.midY)
        expectTrue(
            hitsRow(row, in: container, at: mid),
            "hitTest over \(type(of: subview)) returns the row")
    }
}

/// I5 — sanity check that hiding/showing the warning glyph inside `topRight`
/// still lets the stack collapse/expand as intended, and that repeated
/// flips settle on the same two widths rather than drifting.
private func testWarningStackShrinksAndIsStable() {
    let (_, _, row) = makeHostedRow(width: 300)

    row.configure(with: shortName, state: nil)
    row.layoutSubtreeIfNeeded()
    let widthHidden = topRightStack(in: row).fittingSize.width

    row.configure(with: shortName, state: .init(duplication: nil, problem: .emptyLiteral))
    row.layoutSubtreeIfNeeded()
    let widthShown = topRightStack(in: row).fittingSize.width

    expectTrue(widthHidden < widthShown, "topRight shrinks when the warning glyph is hidden")

    var hiddenWidths: [CGFloat] = []
    var shownWidths: [CGFloat] = []
    for i in 0..<20 {
        let state: VariableSubstitutor.RowState? = (i % 2 == 0)
            ? .init(duplication: nil, problem: .emptyLiteral) : nil
        row.configure(with: shortName, state: state)
        row.layoutSubtreeIfNeeded()
        let width = topRightStack(in: row).fittingSize.width
        if state == nil { hiddenWidths.append(width) } else { shownWidths.append(width) }
    }
    expectTrue(
        Set(hiddenWidths.map { $0.rounded() }).count == 1 && Set(shownWidths.map { $0.rounded() }).count == 1,
        "topRight width is stable across repeated isHidden flips")
}

/// I3 (part 1) — `tint.withAlphaComponent(0.55)` made the braces *more* opaque
/// than the name on the dimmed (unnamed) branch, since `.tertiaryLabelColor`'s
/// own alpha (~0.26) is already below 0.55. The fix uses an explicit
/// quaternary/tertiary pair instead of deriving one, so braces must resolve
/// strictly dimmer than the name they sit around.
private func testDimmedBraceDimmerThanName() {
    let (_, _, row) = makeHostedRow(width: 300)
    row.configure(with: unnamed, state: nil)
    row.layoutSubtreeIfNeeded()

    guard let nameField = row.subviews.first(where: { $0 is NSTextField }) as? NSTextField else {
        failures += 1
        print("FAIL brace color test: name field not found")
        return
    }
    let attr = nameField.attributedStringValue
    let braceColor = colorAt(attr, 0)   // '{'
    let bodyColor = colorAt(attr, 2)    // inside "name" placeholder

    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        let brace = braceColor.usingColorSpace(.deviceRGB)!.alphaComponent
        let body = bodyColor.usingColorSpace(.deviceRGB)!.alphaComponent
        expectTrue(brace < body, "unnamed row: brace alpha (\(brace)) is dimmer than name alpha (\(body))")
    }
}

/// I3 (part 2) — verified in isolation first: `NSColor.systemIndigo` resolves
/// dynamically no matter when it is read, but `.withAlphaComponent(_:)` on it
/// bakes in a snapshot at the moment it's called, evaluated under whatever
/// appearance is current *then* — resolving that snapshot later, under a
/// different `performAsCurrentDrawingAppearance` context, does not change it.
/// `braceColor` for the un-shadowed, problem-free branch is built exactly this
/// way (`.systemIndigo.withAlphaComponent(0.55)`), so it is the attribute that
/// actually freezes — the body colour (`nameTint`, a raw catalog colour with
/// no derivation) was never affected and would pass this test with or without
/// the reconfigure fix, which is why this reads the *brace* attribute (index
/// 0, `"{"`) rather than the body (index 2, the name itself).
private func testColorsFollowAppearanceChange() {
    let (_, _, row) = makeHostedRow(width: 300)
    row.appearance = NSAppearance(named: .aqua)
    row.configure(with: shortName, state: nil)

    guard let nameField = row.subviews.first(where: { $0 is NSTextField }) as? NSTextField else {
        failures += 1
        print("FAIL appearance-follow test: name field not found")
        return
    }

    let lightBraceColor = colorAt(nameField.attributedStringValue, 0)
    var lightRGBA: NSColor!
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        lightRGBA = lightBraceColor.usingColorSpace(.deviceRGB)!
    }

    row.appearance = NSAppearance(named: .darkAqua)

    let darkBraceColor = colorAt(nameField.attributedStringValue, 0)
    var darkRGBA: NSColor!
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        darkRGBA = darkBraceColor.usingColorSpace(.deviceRGB)!
    }

    expectTrue(
        lightRGBA != darkRGBA,
        "brace colour re-resolves after an appearance change (light \(lightRGBA!) != dark \(darkRGBA!))")
}

/// Layout must fully resolve (no under- or over-determined constraint sets)
/// across the widths the panel actually uses, for every row state.
private func testLayoutUnambiguous() {
    let variables: [(QueryVariable, VariableSubstitutor.RowState?)] = [
        (shortName, nil),
        (name56, nil),
        (unnamed, nil),
        (brokenLiteral, .init(duplication: nil, problem: .emptyLiteral)),
        (shortName, .init(duplication: .shadowed, problem: nil)),
    ]
    for width: CGFloat in [180, 300, 600] {
        for (variable, state) in variables {
            let (_, _, row) = makeHostedRow(width: width)
            row.configure(with: variable, state: state)
            row.layoutSubtreeIfNeeded()
            expectTrue(
                !hasAmbiguousLayoutRecursively(row),
                "layout unambiguous at \(Int(width))pt for \(variable.name.isEmpty ? "unnamed" : variable.name)")
        }
    }
}

/// Minor: `configure` gives the row an accessibility identity so VoiceOver
/// sees something actionable instead of an unlabelled group of static texts.
/// Not adversarially tested (no revert/restore cycle) — this only confirms
/// the values `configure` sets are the ones actually readable back.
private func testAccessibilityIdentity() {
    let (_, _, row) = makeHostedRow(width: 300)
    let v = QueryVariable(name: "target_ip", value: "1", type: .literal)
    row.configure(with: v, state: nil)

    expectTrue(row.accessibilityRole() == .button, "row accessibility role is .button")
    expectTrue(
        row.accessibilityLabel()?.contains("target_ip") == true,
        "row accessibility label mentions the variable name")
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    testValueTextViewBuildsOwnTextStack()
    testRowHeightConstantAcrossNameLength()
    testChevronStaysGlyphSized()
    testHitTestReachesRow()
    testWarningStackShrinksAndIsStable()
    testDimmedBraceDimmerThanName()
    testColorsFollowAppearanceChange()
    testLayoutUnambiguous()
    testAccessibilityIdentity()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
