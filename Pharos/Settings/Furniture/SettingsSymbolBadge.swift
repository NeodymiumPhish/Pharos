import AppKit

/// A tinted rounded square with a white SF Symbol on it — the sidebar icon
/// style of the System Settings and Xcode 26 Settings windows.
///
/// Drawn, not layered, for the same reason as `SettingsGroupBox`: the tint
/// is often a dynamic colour, and a draw call re-resolves it each time.
final class SettingsSymbolBadge: NSView {

    var symbolName: String { didSet { needsDisplay = true } }
    var tint: NSColor { didSet { needsDisplay = true } }
    let size: CGFloat

    init(symbolName: String, tint: NSColor, size: CGFloat = SettingsMetrics.rowIconSize) {
        self.symbolName = symbolName
        self.tint = tint
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        // Decorative: the row's title names the thing.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsSymbolBadge is built in code") }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        NSBezierPath(roundedRect: square, xRadius: 5, yRadius: 5).fill(with: tint)

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        symbol.isTemplate = false
        let imageSize = symbol.size
        let origin = NSPoint(x: square.midX - imageSize.width / 2, y: square.midY - imageSize.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: imageSize))
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
