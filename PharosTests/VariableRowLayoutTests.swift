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

/// The row's direct `NSTextField` subviews are added in one order — name,
/// caption, value — so the value preview is the last of the three. Same
/// add-order assumption the name-label accessors above already make.
private func valueLabel(in row: VariableRowView) -> NSTextField {
    let fields = row.subviews.compactMap { $0 as? NSTextField }
    guard fields.count >= 3 else {
        fatalError("expected three direct NSTextField subviews, found \(fields.count)")
    }
    return fields[2]
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

/// A value is pasted data, so its preview is escaped at render: two values
/// differing only by an invisible scalar must not draw identically. The scalar
/// sits mid-value so no trimming in `VariableValuePreview.snippet` can remove
/// it before the escaper sees it.
private func testHostileValuePreviewIsDisclosed() {
    let (_, _, row) = makeHostedRow(width: 320)
    let hostile = QueryVariable(name: "ip", value: "10.0.0\u{200B}.1", type: .literal)
    row.configure(with: hostile, state: nil)
    let shown = valueLabel(in: row).stringValue
    expectTrue(shown.contains("<U+200B>"),
               "the row's value preview discloses a zero-width space")
    expectTrue(!shown.unicodeScalars.contains("\u{200B}"),
               "the raw invisible scalar never reaches the label")
    expectEqual(hostile.value, "10.0.0\u{200B}.1",
                "the variable's own value is not altered — only the preview")
}

// MARK: - VariableListView harness helpers
//
// VariableListView owns no test-visible state beyond its view hierarchy, so
// these helpers locate things by walking public `subviews`/`arrangedSubviews`
// rather than reaching into private stored properties — the same approach
// `chevron(in:)` and `topRightStack(in:)` above already use for VariableRowView.

/// A borderless, never-shown window hosting `list` at an explicit numeric
/// width and height — mirroring `makeHostedRow`'s own pattern above rather
/// than pinning all four edges to `container`. Measured directly: pinning
/// leading/top/trailing/bottom to a `container` whose own size is only ever
/// set via `frame` (not a constraint) leaves nothing in the graph anchored to
/// an absolute number, so Auto Layout is free to resolve `container` itself
/// to a different width than the one it was created with — `list` measured
/// 198pt wide inside a 180pt-wide container this way. An explicit width/height
/// constant on `list` closes that off.
private func makeHostedList(width: CGFloat, height: CGFloat = 600) -> (window: NSWindow, container: NSView, list: VariableListView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container
    let list = VariableListView()
    list.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(list)
    NSLayoutConstraint.activate([
        list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        list.topAnchor.constraint(equalTo: container.topAnchor),
        list.widthAnchor.constraint(equalToConstant: width),
        list.heightAnchor.constraint(equalToConstant: height),
    ])
    container.layoutSubtreeIfNeeded()
    return (window, container, list)
}

private func makeVariables(_ n: Int) -> [QueryVariable] {
    (0..<n).map { QueryVariable(name: "var\($0)", value: "v\($0)", type: .literal) }
}

private func listScrollView(in list: VariableListView) -> NSScrollView {
    list.subviews.compactMap { $0 as? NSScrollView }.first!
}

private func rowsStackView(in list: VariableListView) -> NSStackView {
    listScrollView(in: list).documentView as! NSStackView
}

private func rowViews(in list: VariableListView) -> [VariableRowView] {
    rowsStackView(in: list).arrangedSubviews.compactMap { $0 as? VariableRowView }
}

/// A hairline container is a plain `NSView` (not a `VariableRowView`) whose
/// only subview is the separator line — identified by exclusion (no
/// `NSTextField` descendant) rather than by the separator's own concrete
/// type, since that type is a private implementation detail of
/// `VariableListView`. Distinguishes it from the empty-state container,
/// whose subview is an `NSTextField`.
private func hairlineContainers(in list: VariableListView) -> [NSView] {
    rowsStackView(in: list).arrangedSubviews.filter { view in
        !(view is VariableRowView) && !view.subviews.contains { $0 is NSTextField }
    }
}

private func emptyStateContainer(in list: VariableListView) -> NSView? {
    rowsStackView(in: list).arrangedSubviews.first { view in
        !(view is VariableRowView) && view.subviews.contains { $0 is NSTextField }
    }
}

/// The header title reads "Variables" always; the count label is the other
/// direct-subview NSTextField (empty string or a digit). Neither the title nor
/// the count label are inside the scroll view, so this never collides with
/// the empty-state label above.
private func headerTitleLabel(in list: VariableListView) -> NSTextField {
    list.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Variables" }!
}

private func headerCountLabel(in list: VariableListView) -> NSTextField {
    list.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue != "Variables" }!
}

private func headerAddButton(in list: VariableListView) -> NSButton {
    list.subviews.compactMap { $0 as? NSButton }.first!
}

// MARK: - VariableListView tests

/// Layout must fully resolve — no ambiguity anywhere in the tree — for an
/// empty list, a single row, and a long (~20-row) list, at every width the
/// panel actually uses.
private func testListLayoutUnambiguous() {
    for width: CGFloat in [180, 300, 600] {
        for count in [0, 1, 20] {
            let (_, _, list) = makeHostedList(width: width)
            list.setVariables(makeVariables(count), referenced: [])
            list.layoutSubtreeIfNeeded()
            expectTrue(
                !hasAmbiguousLayoutRecursively(list),
                "list layout unambiguous at \(Int(width))pt with \(count) variable(s)")
        }
    }
}

/// No NSStackView alignment stretches arranged subviews on a vertical stack:
/// `.width` reads like the one that does, and is rejected — assign it and the
/// property comes back `.notAnAttribute`. What holds these rows open is the
/// explicit width pin `setVariables` adds to each row as it builds it, which
/// is why this is measured rather than assumed. It is exactly the stretch that
/// silently failed for the old panel's empty-state label.
///
/// The leading edge is measured alongside the width, because the two fail
/// separately: with no alignment at all a row is pushed toward the TRAILING
/// edge (AppKit's own trailing edge constraint outranks its leading one by ten
/// points), so a row could be the right width in the wrong place.
private func testRowsAreFullWidth() {
    for width: CGFloat in [180, 300, 600] {
        let (_, _, list) = makeHostedList(width: width)
        list.setVariables(makeVariables(5), referenced: [])
        list.layoutSubtreeIfNeeded()
        expectTrue(
            rowsStackView(in: list).alignment == .leading,
            "the rows stack asks for an alignment NSStackView accepts at \(Int(width))pt")
        for (i, row) in rowViews(in: list).enumerated() {
            expectClose(row.frame.width, width, "row \(i) full width at \(Int(width))pt")
            expectClose(row.frame.minX, 0, "row \(i) starts at the leading edge at \(Int(width))pt")
        }
        // The hairlines between the rows too: a hairline that hugged instead
        // would stop short of the trailing edge and read as a ragged list.
        for (i, line) in rowsStackView(in: list).arrangedSubviews.enumerated()
        where !(line is VariableRowView) {
            expectClose(line.frame.width, width, "separator \(i) full width at \(Int(width))pt")
            expectClose(line.frame.minX, 0, "separator \(i) starts at the leading edge at \(Int(width))pt")
        }
    }
}

/// The regression the user actually reported: the old panel's empty-state
/// label sat inset from both edges and centred instead of hugging the
/// leading edge. Pinned here at every width the panel uses.
///
/// Two things measured, not assumed: (1) `NSTextField`'s frame extends
/// `alignmentRectInsets` (2pt a side here) beyond what Auto Layout actually
/// pins — Auto Layout constrains the *alignment rect*, not the raw frame —
/// so the raw-frame minX sits 2pt short of the nominal 10pt inset; comparing
/// against the unadjusted 10 would itself fail on a correctly-pinned label.
/// (2) comparing minX against `width / 2` at a single width is not a
/// reliable "not centred" check: at 180pt this label's own frame happens to
/// span nearly the full available width, so a genuinely centred layout and a
/// properly leading-pinned one land on the same midX by coincidence.
/// Comparing minX *across* widths is unambiguous instead — a fixed-inset pin
/// keeps it constant; proportional centring would grow it with the
/// container.
private func testEmptyStateLabelLeftAligned() {
    var minXByWidth: [CGFloat: CGFloat] = [:]
    for width: CGFloat in [180, 300, 600] {
        let (_, _, list) = makeHostedList(width: width)
        list.setVariables([], referenced: [])
        list.layoutSubtreeIfNeeded()

        guard let container = emptyStateContainer(in: list),
              let label = container.subviews.first(where: { $0 is NSTextField }) as? NSTextField
        else {
            failures += 1
            print("FAIL empty-state label not found at \(Int(width))pt")
            continue
        }

        let frameInList = container.convert(label.frame, to: list)
        let expectedMinX = 10 - label.alignmentRectInsets.left
        expectClose(
            frameInList.minX, expectedMinX,
            "empty-state label minX == 10pt (alignment-rect adjusted) at \(Int(width))pt")
        minXByWidth[width] = frameInList.minX
    }

    if let at180 = minXByWidth[180], let at600 = minXByWidth[600] {
        expectClose(
            at180, at600, tolerance: 1,
            "empty-state label minX is constant across widths (not proportionally centred): 180pt=\(at180), 600pt=\(at600)")
    } else {
        failures += 1
        print("FAIL empty-state label minX comparison: missing measurement")
    }
}

/// A list of N variables must yield N rows and N hairlines in
/// `rowsStack.arrangedSubviews`, each hairline's line inset 10pt from the
/// leading edge and 1pt tall.
private func testHairlinesSeparateRows() {
    for n in [1, 3, 20] {
        let (_, _, list) = makeHostedList(width: 300, height: 2000)
        list.setVariables(makeVariables(n), referenced: [])
        list.layoutSubtreeIfNeeded()

        let rows = rowViews(in: list)
        let hairlines = hairlineContainers(in: list)
        expectTrue(rows.count == n, "\(n) variable(s) yields \(n) rows (got \(rows.count))")
        expectTrue(hairlines.count == n, "\(n) variable(s) yields \(n) hairlines (got \(hairlines.count))")

        for hairline in hairlines {
            expectClose(hairline.frame.height, 1, "hairline container height == 1pt")
            guard let line = hairline.subviews.first else {
                failures += 1
                print("FAIL hairline missing its separator line")
                continue
            }
            let lineInList = hairline.convert(line.frame, to: list)
            expectClose(lineInList.minX, 10, "hairline line inset 10pt from leading edge")
            expectClose(line.frame.height, 1, "hairline line height == 1pt")
        }
    }
}

/// This is C2 one level up: the previous task's defect was decorative
/// subviews covering the row and swallowing hitTest. Here the row is hosted
/// inside the list's scroll view / stack view chain instead of a bare
/// container, so this also confirms nothing in that ancestor chain (the
/// plain, non-passthrough `rowsStack`, the flipped clip view, the scroll
/// view) claims a point that falls on a row before the row itself does.
///
/// The row's own bounding-box centre is checked, but that alone does not
/// discriminate a C2-style regression: proven by reverting
/// `PassthroughTextField`'s hitTest override and finding this check alone
/// kept passing anyway, because for this row's short content the geometric
/// centre falls in blank space between labels, not on any of them. Each
/// row's own subview midpoints (name, caption, value, chevron, …) are the
/// actual locus of that bug, so those are checked too — mirroring
/// `testHitTestReachesRow` above, but exercised through the list's real
/// scroll view / stack view ancestry rather than a bare hosting container.
private func testListHitTestReachesRow() {
    let (_, container, list) = makeHostedList(width: 300)
    list.setVariables(makeVariables(5), referenced: [])
    list.layoutSubtreeIfNeeded()

    for (i, row) in rowViews(in: list).enumerated() {
        expectTrue(
            hitsRow(row, in: container, at: NSPoint(x: row.bounds.midX, y: row.bounds.midY)),
            "hitTest at row \(i)'s centre returns that VariableRowView")
        for subview in row.subviews {
            let mid = NSPoint(x: subview.frame.midX, y: subview.frame.midY)
            expectTrue(
                hitsRow(row, in: container, at: mid),
                "hitTest over row \(i)'s \(type(of: subview)) returns that VariableRowView")
        }
    }
}

/// `updateStates` must re-render in place, not rebuild — a rebuild would drop
/// scroll position and hover. Checked two ways: the row view instances must
/// be identical before and after, and a row's rendering must actually change
/// when its state does (an empty Literal that becomes referenced flags its
/// warning glyph), so this is not a vacuously-true identity check.
private func testUpdateStatesPreservesRowIdentity() {
    let (_, _, list) = makeHostedList(width: 300)
    var variables = makeVariables(3)
    variables[0].type = .literal
    variables[0].value = ""  // empty literal — flags once referenced

    list.setVariables(variables, referenced: [])
    list.layoutSubtreeIfNeeded()

    let before = rowViews(in: list)
    expectTrue(before.count == 3, "updateStates setup: 3 rows present")

    let warningBefore = topRightStack(in: before[0]).subviews.compactMap { $0 as? NSImageView }.first!
    expectTrue(warningBefore.isHidden, "row 0 warning hidden before var0 is referenced")

    list.updateStates(for: variables, referenced: [variables[0].name])
    list.layoutSubtreeIfNeeded()

    let after = rowViews(in: list)
    expectTrue(after.count == before.count, "updateStates keeps the same row count")
    for (i, pair) in zip(before, after).enumerated() {
        expectTrue(pair.0 === pair.1, "updateStates reuses the same VariableRowView instance at index \(i)")
    }

    let warningAfter = topRightStack(in: after[0]).subviews.compactMap { $0 as? NSImageView }.first!
    expectTrue(!warningAfter.isHidden, "row 0 warning becomes visible once var0 is referenced and empty")
}

/// `setVariables` must fully replace the previous content: no stale rows left
/// behind when collapsing to empty, and no leftover empty-state label when
/// filling back in.
private func testSetVariablesClearsProperly() {
    let (_, _, list) = makeHostedList(width: 300, height: 3000)

    list.setVariables(makeVariables(20), referenced: [])
    list.layoutSubtreeIfNeeded()
    expectTrue(rowViews(in: list).count == 20, "20 variables yields 20 rows")

    list.setVariables([], referenced: [])
    list.layoutSubtreeIfNeeded()
    expectTrue(rowViews(in: list).isEmpty, "20 -> 0 variables leaves no rows")
    expectTrue(emptyStateContainer(in: list) != nil, "20 -> 0 variables shows the empty state")
    expectTrue(
        rowsStackView(in: list).arrangedSubviews.count == 1,
        "20 -> 0 variables leaves exactly one arranged subview (the empty state), got \(rowsStackView(in: list).arrangedSubviews.count)")

    list.setVariables(makeVariables(3), referenced: [])
    list.layoutSubtreeIfNeeded()
    expectTrue(rowViews(in: list).count == 3, "0 -> 3 variables yields 3 rows")
    expectTrue(emptyStateContainer(in: list) == nil, "0 -> 3 variables removes the empty state")
    expectTrue(
        rowsStackView(in: list).arrangedSubviews.count == 6,
        "0 -> 3 variables leaves exactly 6 arranged subviews (3 rows + 3 hairlines), got \(rowsStackView(in: list).arrangedSubviews.count)")
}

/// `countLabel` mirrors the variable count (blank when empty, not "0"), and
/// `addButton` sits pinned `trailing - 8` regardless of width.
private func testHeaderReflectsCountAndLayout() {
    for width: CGFloat in [180, 300, 600] {
        let (_, _, list) = makeHostedList(width: width)

        list.setVariables([], referenced: [])
        list.layoutSubtreeIfNeeded()
        expectEqual(headerCountLabel(in: list).stringValue, "", "countLabel empty for empty list at \(Int(width))pt")

        list.setVariables(makeVariables(3), referenced: [])
        list.layoutSubtreeIfNeeded()
        expectEqual(headerCountLabel(in: list).stringValue, "3", "countLabel shows 3 for three variables at \(Int(width))pt")

        let button = headerAddButton(in: list)
        expectClose(button.frame.maxX, width - 8, "addButton trailing == width - 8 at \(Int(width))pt")
    }
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
    testHostileValuePreviewIsDisclosed()

    testListLayoutUnambiguous()
    testRowsAreFullWidth()
    testEmptyStateLabelLeftAligned()
    testHairlinesSeparateRows()
    testListHitTestReachesRow()
    testUpdateStatesPreservesRowIdentity()
    testSetVariablesClearsProperly()
    testHeaderReflectsCountAndLayout()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
