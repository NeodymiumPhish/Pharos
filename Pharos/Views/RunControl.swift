import AppKit
import Combine

/// The toolbar's Run | Cancel transport control.
///
/// One momentary segmented control in ONE view item, so both commands share a
/// single glass platter, as Xcode's run and stop controls do. Measured
/// 2026-09-30 in a scratch app: this gives one `NSToolbarPlatterView`, where two
/// view items get one each.
///
/// While anything runs, the Cancel glyph breathes in the accent colour on the
/// shared `PulseClock` (see `RunControlState`). The toolbar applies
/// `update(canRun:runningCount:)`; the control keeps the pulse going on its own
/// and holds the clock only while something runs.
final class RunControl: NSSegmentedControl {

    enum Segment: Int {
        case run = 0
        case cancel = 1
    }

    /// Called with the segment the user pressed.
    var onPress: ((Segment) -> Void)?

    private(set) var state = RunControlState(canRun: false, runningCount: 0, pulse: 1)

    private var canRun = false
    private var runningCount = 0
    private var pulseSubscription: AnyCancellable?
    private var hasApplied = false

    private static let segmentWidth: CGFloat = 34
    private let runImage = NSImage(systemSymbolName: "play.fill",
                                   accessibilityDescription: RunControlState.runAccessibilityLabel)!
    private let idleCancelImage = NSImage(systemSymbolName: "stop.fill",
                                          accessibilityDescription: String(localized: "Cancel Query"))!
    /// The Cancel glyph at each pulse step. Not templates, so the control keeps
    /// the accent instead of tinting them like its other glyphs.
    private lazy var pulseImages: [NSImage] = (0..<RunControlState.tintSteps).map { step in
        let color = NSColor.controlAccentColor.withAlphaComponent(RunControlState.alpha(forStep: step))
        let image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))!
        image.isTemplate = false
        return image
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        segmentCount = 2
        trackingMode = .momentary
        for segment in [Segment.run, .cancel] {
            setWidth(Self.segmentWidth, forSegment: segment.rawValue)
        }
        setImage(runImage, forSegment: Segment.run.rawValue)
        setImage(idleCancelImage, forSegment: Segment.cancel.rawValue)
        setToolTip(RunControlState.runToolTip, forSegment: Segment.run.rawValue)
        target = self
        action = #selector(segmentPressed(_:))
        setAccessibilityIdentifier("toolbar.runControl")
        apply(pulse: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Show the active tab's state. Cheap to call often: the control only
    /// touches what changed.
    func update(canRun: Bool, runningCount: Int) {
        self.canRun = canRun
        self.runningCount = runningCount
        if runningCount > 0, pulseSubscription == nil {
            let token = PulseClock.shared.observe()
            let sink = PulseClock.shared.value.sink { [weak self] value in
                self?.apply(pulse: value)
            }
            pulseSubscription = AnyCancellable {
                sink.cancel()
                token.cancel()
            }
        } else if runningCount == 0 {
            // Released at once, so the clock stops when nothing else pulses.
            pulseSubscription = nil
        }
        apply(pulse: PulseClock.shared.value.value)
    }

    /// Whether the control currently holds the pulse clock.
    var isPulsing: Bool { pulseSubscription != nil }

    /// Where the running-queries list points: the Cancel half of the control.
    var cancelSegmentRect: NSRect {
        NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
    }

    private func apply(pulse: CGFloat) {
        let next = RunControlState(canRun: canRun, runningCount: runningCount, pulse: pulse)
        let first = !hasApplied
        guard first || next != state else { return }
        let previous = state
        state = next
        hasApplied = true

        setEnabled(next.runEnabled, forSegment: Segment.run.rawValue)
        setEnabled(next.cancelEnabled, forSegment: Segment.cancel.rawValue)

        if first || next.tintStep != previous.tintStep
            || next.cancelAccessibilityLabel != previous.cancelAccessibilityLabel {
            let image = next.tintStep.map { pulseImages[$0] } ?? idleCancelImage
            image.accessibilityDescription = next.cancelAccessibilityLabel
            setImage(image, forSegment: Segment.cancel.rawValue)
        }
        if first || next.cancelToolTip != previous.cancelToolTip {
            setToolTip(next.cancelToolTip, forSegment: Segment.cancel.rawValue)
        }
    }

    @objc private func segmentPressed(_ sender: Any?) {
        guard let segment = Segment(rawValue: selectedSegment) else { return }
        onPress?(segment)
    }
}
