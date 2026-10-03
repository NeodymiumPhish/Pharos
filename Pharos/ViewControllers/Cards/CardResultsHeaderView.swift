import AppKit

/// The results area's header: whose results these are. A colour swatch, the
/// card's name and version, what the run returned and when, and Go to Card.
///
/// Colour is never the only signal (HIG, Accessibility): the name is always
/// written out.
final class CardResultsHeaderView: NSView {
    static let height: CGFloat = 28

    var onGoToCard: (() -> Void)?

    private let swatch = SwatchView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let goToCardButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        goToCardButton.title = String(localized: "Go to Card")
        goToCardButton.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
        goToCardButton.imagePosition = .imageLeading
        goToCardButton.bezelStyle = .push
        goToCardButton.controlSize = .small
        goToCardButton.target = self
        goToCardButton.action = #selector(goToCard)
        goToCardButton.toolTip = String(localized: "Scroll the cards to the one these results belong to")
        goToCardButton.setAccessibilityIdentifier("results.goToCard")
        goToCardButton.setAccessibilityLabel(String(localized: "Go to Card"))

        swatch.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [swatch, titleLabel, metaLabel, NSView(), goToCardButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            // 999: holds whenever the header has a width; gives way quietly
            // in the first layout at width 0 instead of breaking a required one.
            { let edge = row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
              edge.priority = NSLayoutConstraint.Priority(999)
              return edge }(),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("results.cardHeader")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Show the header for one card's results.
    func show(title: String, versionChip: String?, meta: String, color: NSColor?) {
        titleLabel.stringValue = [title, versionChip].compactMap { $0 }.joined(separator: " ")
        metaLabel.stringValue = meta
        swatch.color = color ?? .separatorColor
        setAccessibilityLabel(String(localized: "Results of \(titleLabel.stringValue)"))
    }

    @objc private func goToCard() { onGoToCard?() }

    override func draw(_ dirtyRect: NSRect) {
        let tint = (swatch.color).withAlphaComponent(0.07)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        tint.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The card's colour as a small rounded square.
private final class SwatchView: NSView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }
}
