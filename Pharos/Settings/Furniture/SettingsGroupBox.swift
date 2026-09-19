import AppKit

/// A rounded plate holding a column of `SettingsRow`s, with a hairline border
/// and a separator between neighbouring rows — the inset-grouped look of the
/// Xcode 26 Settings window.
///
/// The plate, border and separators are all drawn in `draw(_:)` rather than
/// set on a layer: a dynamic `NSColor` written into a layer as a `CGColor`
/// resolves once and never follows an appearance change, whereas a draw call
/// resolves against the current appearance every time.
final class SettingsGroupBox: NSView {

    /// Top-down, so the separator maths reads row frames the way they stack.
    override var isFlipped: Bool { true }

    /// Where a separator starts, from the leading edge. Rows that show an icon
    /// align their text past the icon, and the separator should start at that
    /// text edge (`rowInsetH + rowIconSize + iconTextGap`); rows without one
    /// start at `rowInsetH`.
    var separatorLeadingInset: CGFloat = SettingsMetrics.rowInsetH {
        didSet { needsDisplay = true }
    }

    /// The rows, in order, top to bottom.
    var rows: [NSView] { stack.arrangedSubviews }

    private let stack = NSStackView()

    init(title: String?, rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { stack.addArrangedSubview(row) }
        // The rows span the plate. Not `.width` — see NSStackView+SpanFullWidth.
        stack.spanArrangedSubviewsFullWidth()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A row that shows an icon moves its text past the icon, so the
        // separators follow that edge.
        if rows.contains(where: { ($0 as? SettingsRow)?.showsIcon == true }) {
            separatorLeadingInset = SettingsMetrics.rowInsetH
                + SettingsMetrics.rowIconSize + SettingsMetrics.iconTextGap
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        if let title, !title.isEmpty { setAccessibilityLabel(title) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsGroupBox is built in code") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = SettingsMetrics.boxCornerRadius

        // Plate.
        let plate = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        SettingsMetrics.plateColor.setFill()
        plate.fill()

        // Border and separators. Increase Contrast wants an unmistakable edge,
        // so the hairline goes opaque and takes the label ink.
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let ink: NSColor = highContrast
            ? NSColor.labelColor.withAlphaComponent(1)
            : SettingsMetrics.borderColor

        let separators = stack.arrangedSubviews.dropFirst()
        if !separators.isEmpty {
            ink.setFill()
            let leading = separatorLeadingInset
            for row in separators {
                // Flipped, so a row's minY is its TOP edge; the separator sits
                // on the boundary with the row above it.
                let y = stack.convert(row.frame, to: self).minY
                NSBezierPath.fill(NSRect(x: leading, y: y, width: bounds.width - leading, height: 1))
            }
        }

        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        ink.setStroke()
        border.stroke()
    }
}
