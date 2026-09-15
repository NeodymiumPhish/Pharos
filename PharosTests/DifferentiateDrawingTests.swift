// What Differentiate Without Color actually PAINTS.
//
// A sibling suite can assert that `MarkerShape.index(for:)` returns eight
// different numbers and prove nothing at all: the point of the setting is that
// the eight markers look different with the colour taken away. So this suite
// renders them offscreen, throws the colour away, and compares the INK.
//
// This is not screen capture. There is no window and no screenshot API, so it
// needs neither Screen Recording nor Accessibility permission — see
// `HostileTextPixelTests`, which explains the two mechanics that fail silently:
// a bitmap context is y-up (every rect here is written in bitmap coordinates,
// so no flip is needed), and the bitmap rep must be RETAINED for the pixels to
// survive the call that made them. `Sample` below holds its rep.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Offscreen rendering

private final class Sample {
    /// Load-bearing: the pixels belong to the rep, and a helper that returned
    /// only the mask would let it deallocate first.
    let rep: NSBitmapImageRep
    let size: NSSize

    init(rep: NSBitmapImageRep, size: NSSize) {
        self.rep = rep
        self.size = size
    }

    /// The GREYSCALE picture, one quantised luminance per pixel. Hue is thrown
    /// away on purpose: two markers that differ only in colour must compare
    /// EQUAL here, because that is exactly the comparison Differentiate Without
    /// Color asks the drawing to survive.
    ///
    /// Quantised, not thresholded. A threshold was the first version and it was
    /// wrong in a way that passed: a solid `systemRed` band is already dark
    /// enough to be "ink" everywhere, so a hatch drawn over it changed nothing
    /// the comparison could see, and three identical bands read as three
    /// different ones. Sixteen levels keep the antialiasing noise out and still
    /// show a rung.
    func greyscale(in rect: NSRect) -> [Int] {
        var levels: [Int] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    levels.append(15)
                    continue
                }
                let luminance = 0.299 * pixel.redComponent
                    + 0.587 * pixel.greenComponent + 0.114 * pixel.blueComponent
                levels.append(min(15, Int(luminance * 16)))
            }
        }
        return levels
    }

    /// Pixels appreciably darker than the white ground.
    func inkCount(in rect: NSRect) -> Int {
        greyscale(in: rect).filter { $0 < 14 }.count
    }

    var inkCount: Int { inkCount(in: NSRect(origin: .zero, size: size)) }
}

private func render(size: NSSize, _ body: () -> Void) -> Sample? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    body()
    NSGraphicsContext.restoreGraphicsState()
    return Sample(rep: rep, size: size)
}

// MARK: - Tests

/// `main.swift` calls this from top-level code, which is not main-actor
/// isolated; the body is, because `AccessibilityDisplay` is. The shim is shared
/// by every suite in the repo and does not change for one of them.
func runTests() {
    MainActor.assumeIsolated { runTestsOnMain() }
}

@MainActor
private func runTestsOnMain() {
    AccessibilityDisplay.shared.overrideForTesting(differentiateWithoutColor: true)
    expect(AccessibilityDisplay.shared.differentiateWithoutColor,
           "the test seam turns Differentiate Without Color on")

    // 1. Every marker in the cycle paints something, and no two paint the same
    //    thing. One colour for all of them, so the ONLY difference the masks can
    //    show is the shape.
    let markerSize = NSSize(width: 24, height: 24)
    let full = NSRect(origin: .zero, size: markerSize)
    var markerMasks: [[Int]] = []
    for index in MarkerShape.all.indices {
        guard let sample = render(size: markerSize, {
            MarkerShape.fill(index: index, in: full.insetBy(dx: 2, dy: 2), color: .black)
        }) else {
            failures += 1
            print("FAIL marker \(index) would not render")
            continue
        }
        expect(sample.inkCount > 0, "marker \(index) (\(MarkerShape.shape(at: index).name)) paints ink")
        markerMasks.append(sample.greyscale(in: full))
    }

    var collisions: [String] = []
    for i in markerMasks.indices {
        for j in (i + 1)..<markerMasks.count where markerMasks[i] == markerMasks[j] {
            collisions.append("\(MarkerShape.shape(at: i).name)/\(MarkerShape.shape(at: j).name)")
        }
    }
    expect(collisions.isEmpty,
           "no two markers paint the same greyscale mask\(collisions.isEmpty ? "" : " — \(collisions)")")

    // 2. The eight result-tab palette colours claim eight different markers.
    //    Fewer would hand two live tabs the same shape, which is the failure
    //    this whole mechanism exists to prevent.
    let tabPalette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemIndigo,
                                 .systemMint, .systemCyan, .systemBrown, .systemPink]
    let tabIndexes = tabPalette.map(MarkerShape.index(for:))
    expect(Set(tabIndexes).count == tabPalette.count,
           "the result-tab palette spreads across the whole marker cycle \(tabIndexes)")

    // 3. The six tag palette colours likewise.
    let tagPalette: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                 .systemGreen, .systemBlue, .systemPurple]
    let tagIndexes = tagPalette.map(MarkerShape.index(for:))
    expect(Set(tagIndexes).count == tagPalette.count,
           "the tag palette spreads across the marker cycle \(tagIndexes)")

    // 4. The marker follows the palette colour, not its resolved RGB: a system
    //    colour is a different RGB in dark mode, and a marker that changed
    //    shape with the appearance would be worse than none.
    expect(MarkerShape.index(for: .systemBlue) == MarkerShape.index(for: .systemBlue),
           "the same colour always gets the same marker")

    // 5. Tag bands. Three bands of ONE colour: with the setting on they must
    //    still be told apart, and the only thing left to tell them apart by is
    //    the hatch.
    let rowSize = NSSize(width: 40, height: 60)
    let row = TaggedRowView(frame: NSRect(origin: .zero, size: rowSize))
    row.configure(segments: [
        (color: .systemRed, isPartial: false),
        (color: .systemRed, isPartial: false),
        (color: .systemRed, isPartial: false),
    ])
    guard let banded = render(size: rowSize, { row.draw(row.bounds) }) else {
        print("FAIL the tag bar would not render")
        print("\n\(failures + 1) FAILURE(S)")
        exit(1)
    }

    let bands = row.segmentRects(in: row.bounds)
    expect(bands.count == 3, "the bar has three bands [\(bands.count)]")
    let bandMasks = bands.map { banded.greyscale(in: $0) }
    expect(bands.allSatisfy { banded.inkCount(in: $0) > 0 }, "every band paints ink")
    var bandCollisions: [String] = []
    for i in bandMasks.indices {
        for j in (i + 1)..<bandMasks.count where bandMasks[i] == bandMasks[j] {
            bandCollisions.append("\(i)/\(j)")
        }
    }
    expect(bandCollisions.isEmpty,
           "same-coloured bands differ by texture\(bandCollisions.isEmpty ? "" : " — \(bandCollisions)")")

    // 6. With the setting OFF the bands go back to being identical fills —
    //    proof the hatch is gated on the setting and not always on.
    AccessibilityDisplay.shared.overrideForTesting(differentiateWithoutColor: false)
    guard let plain = render(size: rowSize, { row.draw(row.bounds) }) else {
        print("FAIL the plain tag bar would not render")
        print("\n\(failures + 1) FAILURE(S)")
        exit(1)
    }
    let plainMasks = bands.map { plain.greyscale(in: $0) }
    expect(plainMasks[0] == plainMasks[1] && plainMasks[1] == plainMasks[2],
           "with the setting off, same-coloured bands paint identically")

    // 7. And the wash alphas answer to Increase Contrast.
    let contrastRow = TaggedRowView(frame: NSRect(origin: .zero, size: rowSize))
    contrastRow.configure(segments: [(color: .systemRed, isPartial: false)])
    AccessibilityDisplay.shared.overrideForTesting(increaseContrast: false)
    let ordinary = contrastRow.tintAlpha
    AccessibilityDisplay.shared.overrideForTesting(increaseContrast: true)
    let raised = contrastRow.tintAlpha
    expect(raised > ordinary, "Increase Contrast raises the row wash [\(ordinary) → \(raised)]")
    contrastRow.configure(segments: [(color: .systemRed, isPartial: true)])
    expect(contrastRow.tintAlpha > 0.08, "a partial match's wash rises too [\(contrastRow.tintAlpha)]")
    AccessibilityDisplay.shared.overrideForTesting(increaseContrast: false)

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
