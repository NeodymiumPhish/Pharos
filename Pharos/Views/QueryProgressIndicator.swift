import AppKit

/// Animated indicator shown in place of the Run/Stop button while queries are
/// in flight. A red ring (270° arc) spins continuously around a centered count
/// number ("1", "2", "3", …). One consistent visual for any running count.
final class QueryProgressIndicator: NSView {

    private let ringLayer = CAShapeLayer()
    private let countLabel = NSTextField(labelWithString: "")

    var count: Int = 0 {
        didSet {
            countLabel.stringValue = "\(count)"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = NSColor.systemRed.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
        layer?.addSublayer(ringLayer)

        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        countLabel.textColor = .systemRed
        countLabel.alignment = .center
        countLabel.backgroundColor = .clear
        countLabel.isBezeled = false
        countLabel.isEditable = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        updateRingPath()
        startAnimationIfNeeded()
    }

    private func updateRingPath() {
        let inset: CGFloat = 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0 else { return }
        let radius = rect.width / 2

        // 270° arc, opening at the top-right (so the gap is visible during rotation).
        let path = CGMutablePath()
        let startAngle: CGFloat = .pi / 4          // 45° from +x axis
        let endAngle: CGFloat = startAngle + (3 * .pi / 2)
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        ringLayer.frame = bounds
        ringLayer.path = path
    }

    private var animationStarted = false

    private func startAnimationIfNeeded() {
        guard !animationStarted, ringLayer.path != nil else { return }
        animationStarted = true
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = -CGFloat.pi * 2
        anim.duration = 1.4
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        ringLayer.add(anim, forKey: "spin")
    }

    /// Pass clicks through to the runStopButton beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
