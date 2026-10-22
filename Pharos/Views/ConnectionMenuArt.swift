import AppKit

/// The tile at the head of a connection pop-up row: the engine's symbol on a
/// tinted rounded square, and the connection-state dot at its corner (the
/// same colours as the native tab's dot, an empty ring when not connected).
///
/// Drawn with a drawing handler, so the system colours resolve for the light
/// or dark menu each time the image is drawn.
enum ConnectionTile {
    enum Kind: Equatable {
        case server, file, memory
    }

    static func image(kind: Kind, state: TabConnectionState, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tint = color(of: kind)
            let tile = rect.insetBy(dx: 1, dy: 1)
            let radius = size * 0.24
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()

            let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
                .applying(.init(paletteColors: [tint]))
            if let symbol = NSImage(systemSymbolName: symbolName(of: kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2,
                                       width: s.width, height: s.height))
            }

            guard state != .none else { return true }
            // The dot sits on a disc of the menu's own colour, so it reads as
            // cut out of the tile's corner.
            let d = max(7, size * 0.36)
            let disc = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: disc).fill()
            let dot = disc.insetBy(dx: d * 0.18, dy: d * 0.18)
            if let fill = state.fill {
                fill.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                NSColor.tertiaryLabelColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.accessibilityDescription = state.label
        return image
    }

    static func color(of kind: Kind) -> NSColor {
        switch kind {
        case .server: return .systemBlue
        case .file: return .systemOrange
        case .memory: return .systemPurple
        }
    }

    static func symbolName(of kind: Kind) -> String {
        switch kind {
        case .server: return "server.rack"
        case .file: return "cylinder"
        case .memory: return "memorychip"
        }
    }
}

/// A group header in the connection pop-up: a symbol, the title in the
/// label colour at the menu's own size and a medium weight, and a count. It is
/// a menu item's view, never selected: keyboard navigation and type-select
/// pass over it, and VoiceOver reads "PostgreSQL, 16".
final class ConnectionMenuHeaderView: NSView {
    let title: String
    let count: Int

    init(title: String, symbolName: String, count: Int) {
        self.title = title
        self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        autoresizingMask = [.width]

        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        symbol.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 7
        capsule.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        for v in [symbol, label, capsule, countLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setAccessibilityElement(false)
        }
        capsule.addSubview(countLabel)
        addSubview(symbol)
        addSubview(label)
        addSubview(capsule)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 16),
            capsule.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            countLabel.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -5),
            countLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title), \(count)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // The capsule's layer colour does not follow an appearance change by itself.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            subviews.last(where: { $0.wantsLayer })?.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }
}
