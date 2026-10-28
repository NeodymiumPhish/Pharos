import AppKit

/// A manager sidebar row: badge, title, optional subtitle, trailing marks.
///
/// Sized by the table's `effectiveRowSizeStyle`, so the row follows the
/// Sidebar icon size in System Settings ▸ Appearance as Finder's and Mail's
/// sidebars do. The labels are NOT handed to `textField`: `NSTableCellView`
/// would then set the title's font for the size style itself, over a
/// monospaced title. `Metrics` sets the same sizes it would (measured below).
///
/// Every colour here is resolved at draw time. The badge, swatch and marks
/// are drawn views, and the labels use system colours, so a switch between
/// Light and Dark repaints with no reload.
final class ManagerSidebarCell: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("manager.sidebar.cell")

    // MARK: Metrics

    /// The type and badge sizes for one sidebar size.
    struct Metrics: Equatable {
        let titleSize: CGFloat
        let subtitleSize: CGFloat
        let badgeSize: CGFloat

        /// The title sizes are the ones `NSTableCellView` gives its own
        /// `textField` in a source list — 11, 13 and 15 pt — measured on
        /// macOS 27 (2026-10-28) and checked against AppKit by
        /// `scripts/test-manager-sidebar.sh`, so a change in a later macOS
        /// shows up as a failure rather than as a sidebar out of step.
        static func forStyle(_ style: NSTableView.RowSizeStyle) -> Metrics {
            switch style {
            case .small: return Metrics(titleSize: 11, subtitleSize: 10, badgeSize: 16)
            case .large: return Metrics(titleSize: 15, subtitleSize: 13, badgeSize: 24)
            default: return Metrics(titleSize: 13, subtitleSize: 11, badgeSize: SettingsMetrics.rowIconSize)
            }
        }

        /// Title to subtitle.
        static let lineGap: CGFloat = 1

        /// The height a subtitle adds under the title.
        var subtitleLineHeight: CGFloat {
            let font = NSFont.systemFont(ofSize: subtitleSize)
            return ceil(font.ascender - font.descender) + Self.lineGap
        }

        func titleFont(monospaced: Bool) -> NSFont {
            monospaced ? .monospacedSystemFont(ofSize: titleSize, weight: .regular)
                : .systemFont(ofSize: titleSize)
        }
    }

    /// The height of a row: the table's own row height for the size style,
    /// plus one caption line when there is a subtitle.
    static func rowHeight(base: CGFloat, style: NSTableView.RowSizeStyle, hasSubtitle: Bool) -> CGFloat {
        hasSubtitle ? base + Metrics.forStyle(style).subtitleLineHeight : base
    }

    // MARK: Views

    /// Rebuilt when the size style changes: the furniture badge's size is
    /// fixed at init.
    private var symbolBadge = SettingsSymbolBadge(symbolName: "circle", tint: .systemGray)
    private let swatch = ManagerSwatchView()
    /// The badge's slot. Holds whichever of the two badges is on show, so the
    /// title's leading edge does not depend on which.
    private let badgeSlot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let accessoryStack = NSStackView()

    private var badgeWidth: NSLayoutConstraint!
    private var titleAfterBadge: NSLayoutConstraint!
    private var titleAtLeading: NSLayoutConstraint!
    /// Active for a one-line row: the title alone fills the text block.
    private var titleClosesBlock: NSLayoutConstraint!
    /// Active for a two-line row: the subtitle closes the text block.
    private var subtitleClosesBlock: NSLayoutConstraint!
    private var subtitleUnderTitle: NSLayoutConstraint!

    private var item: ManagerSidebarItem?
    private var metrics = Metrics.forStyle(.medium)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("ManagerSidebarCell is built in code") }

    /// Labels and badge are DIRECT subviews, not in a stack: the cell
    /// forwards `backgroundStyle` to its subviews, and that is what turns a
    /// label's text white on the emphasized selection.
    private func build() {
        badgeSlot.translatesAutoresizingMaskIntoConstraints = false
        swatch.translatesAutoresizingMaskIntoConstraints = false
        badgeSlot.addSubview(swatch)
        installSymbolBadge()

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 4
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(badgeSlot)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(accessoryStack)

        // The text block: title, and the subtitle under it when there is
        // one, centred on the row as a unit.
        let block = NSLayoutGuide()
        addLayoutGuide(block)

        badgeWidth = badgeSlot.widthAnchor.constraint(equalToConstant: metrics.badgeSize)
        titleAfterBadge = titleLabel.leadingAnchor.constraint(equalTo: badgeSlot.trailingAnchor, constant: 8)
        titleAtLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        titleClosesBlock = titleLabel.bottomAnchor.constraint(equalTo: block.bottomAnchor)
        subtitleClosesBlock = subtitleLabel.bottomAnchor.constraint(equalTo: block.bottomAnchor)
        subtitleUnderTitle = subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor,
                                                                constant: Metrics.lineGap)

        NSLayoutConstraint.activate([
            badgeSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badgeSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeWidth,
            badgeSlot.heightAnchor.constraint(equalTo: badgeSlot.widthAnchor),
            swatch.topAnchor.constraint(equalTo: badgeSlot.topAnchor),
            swatch.bottomAnchor.constraint(equalTo: badgeSlot.bottomAnchor),
            swatch.leadingAnchor.constraint(equalTo: badgeSlot.leadingAnchor),
            swatch.trailingAnchor.constraint(equalTo: badgeSlot.trailingAnchor),

            block.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: block.topAnchor),
            titleAfterBadge,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -6),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -6),
            titleClosesBlock,

            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyMetrics()
    }

    private func installSymbolBadge() {
        symbolBadge.removeFromSuperview()
        symbolBadge = SettingsSymbolBadge(symbolName: symbolBadge.symbolName, tint: symbolBadge.tint,
                                          size: metrics.badgeSize)
        badgeSlot.addSubview(symbolBadge)
        NSLayoutConstraint.activate([
            symbolBadge.centerXAnchor.constraint(equalTo: badgeSlot.centerXAnchor),
            symbolBadge.centerYAnchor.constraint(equalTo: badgeSlot.centerYAnchor),
            symbolBadge.widthAnchor.constraint(equalToConstant: metrics.badgeSize),
            symbolBadge.heightAnchor.constraint(equalToConstant: metrics.badgeSize),
        ])
    }

    // MARK: Size style

    /// Set by the table to its `effectiveRowSizeStyle`.
    override var rowSizeStyle: NSTableView.RowSizeStyle {
        didSet {
            let next = Metrics.forStyle(rowSizeStyle)
            // `badgeWidth` is nil until `build()` has run, and AppKit may set
            // the style from inside `super.init`.
            guard next != metrics, badgeWidth != nil else { return }
            metrics = next
            installSymbolBadge()
            if let item { configure(item) }
            applyMetrics()
        }
    }

    private func applyMetrics() {
        badgeWidth.constant = metrics.badgeSize
        titleLabel.font = metrics.titleFont(monospaced: item?.titleIsMonospaced ?? false)
        subtitleLabel.font = .systemFont(ofSize: metrics.subtitleSize)
    }

    // MARK: Selection

    /// The title and subtitle colours for a background, as a pair the
    /// harness measures in Light and Dark. On the emphasized (accent)
    /// selection both lines take the selected-text colour: the secondary grey
    /// would sink into the accent fill.
    static func textColors(for style: NSView.BackgroundStyle) -> (title: NSColor, subtitle: NSColor) {
        style == .emphasized
            ? (.alternateSelectedControlTextColor, .alternateSelectedControlTextColor)
            : (.labelColor, .secondaryLabelColor)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let colors = Self.textColors(for: backgroundStyle)
        titleLabel.textColor = colors.title
        subtitleLabel.textColor = colors.subtitle
        let emphasized = backgroundStyle == .emphasized
        for case let mark as ManagerSidebarAccessoryView in accessoryStack.arrangedSubviews {
            mark.isOnEmphasizedSelection = emphasized
        }
    }

    // MARK: Content

    func configure(_ item: ManagerSidebarItem) {
        self.item = item

        switch item.badge {
        case .none:
            badgeSlot.isHidden = true
        case let .symbol(name, tint):
            badgeSlot.isHidden = false
            symbolBadge.isHidden = false
            swatch.isHidden = true
            symbolBadge.symbolName = name
            symbolBadge.tint = tint ?? .systemGray
        case let .swatch(color):
            badgeSlot.isHidden = false
            symbolBadge.isHidden = true
            swatch.isHidden = false
            swatch.color = color
        }
        // Deactivate first: both are required, and holding both for a moment
        // is a conflict AppKit logs.
        if badgeSlot.isHidden {
            titleAfterBadge.isActive = false
            titleAtLeading.isActive = true
        } else {
            titleAtLeading.isActive = false
            titleAfterBadge.isActive = true
        }

        titleLabel.stringValue = item.title
        titleLabel.font = metrics.titleFont(monospaced: item.titleIsMonospaced)

        let subtitle = item.subtitle ?? ""
        subtitleLabel.stringValue = subtitle
        subtitleLabel.lineBreakMode = item.subtitleTruncatesMiddle ? .byTruncatingMiddle : .byTruncatingTail
        let hasSubtitle = !subtitle.isEmpty
        subtitleLabel.isHidden = !hasSubtitle
        // Deactivate before activating, so the two closers never both hold.
        if hasSubtitle {
            titleClosesBlock.isActive = false
            subtitleUnderTitle.isActive = true
            subtitleClosesBlock.isActive = true
        } else {
            subtitleClosesBlock.isActive = false
            subtitleUnderTitle.isActive = false
            titleClosesBlock.isActive = true
        }

        for view in accessoryStack.arrangedSubviews {
            accessoryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for accessory in item.trailing {
            accessoryStack.addArrangedSubview(ManagerSidebarAccessoryView(accessory))
        }
        applyColors()

        // On the LABEL: AppKit does not carry a cell view's or a row view's
        // accessibility identifier into the AXCell / AXRow it publishes, and
        // the label is the element an AX script can find (lessons, 2026-09-19).
        let axId = "manager.sidebar.\(item.id)"
        setAccessibilityIdentifier(axId)
        titleLabel.setAccessibilityIdentifier(axId)
        titleLabel.setAccessibilityLabel(item.title)
    }

    // MARK: Test seams

    var titleField: NSTextField { titleLabel }
    var subtitleField: NSTextField { subtitleLabel }
    var accessoryViews: [ManagerSidebarAccessoryView] {
        accessoryStack.arrangedSubviews.compactMap { $0 as? ManagerSidebarAccessoryView }
    }
    var currentMetrics: Metrics { metrics }
}

// MARK: - Swatch

/// A filled colour dot centred in the badge slot, scaled with it: 12 pt in
/// the 20 pt slot, the size of `TagPalette.swatch`.
final class ManagerSwatchView: NSView {

    var color: NSColor = .systemGray { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Decorative: the row's title names the thing.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("ManagerSwatchView is built in code") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = (min(bounds.width, bounds.height) * 0.6).rounded()
        let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

// MARK: - Trailing marks

/// One `ManagerSidebarItem.Accessory`, drawn.
final class ManagerSidebarAccessoryView: NSView {

    let accessory: ManagerSidebarItem.Accessory

    /// True on the accent selection, where the warning triangle turns to the
    /// selected-text colour (red on the accent fill does not read). The dots
    /// keep their colour: the colour is what they mean.
    var isOnEmphasizedSelection = false { didSet { needsDisplay = true } }

    static let unsavedDotDiameter: CGFloat = 6
    static let statusDotDiameter: CGFloat = 8

    init(_ accessory: ManagerSidebarItem.Accessory) {
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        switch accessory {
        case let .warning(tooltip):
            toolTip = tooltip
            setAccessibilityLabel(tooltip)
        case .unsavedDot:
            setAccessibilityLabel(String(localized: "Unsaved changes"))
        case let .statusDot(_, label):
            setAccessibilityLabel(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("ManagerSidebarAccessoryView is built in code") }

    override var intrinsicContentSize: NSSize {
        switch accessory {
        case .warning: return NSSize(width: 14, height: 14)
        case .unsavedDot, .statusDot: return NSSize(width: 10, height: 10)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The colour the mark paints in, resolved by the caller's appearance.
    var paintColor: NSColor? {
        switch accessory {
        case .warning:
            return isOnEmphasizedSelection ? .alternateSelectedControlTextColor : .systemRed
        case .unsavedDot:
            return .systemOrange
        case let .statusDot(color, _):
            return color
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch accessory {
        case .warning:
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [paintColor ?? .systemRed]))
            guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let size = symbol.size
            symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height))
        case .unsavedDot:
            fillDot(diameter: Self.unsavedDotDiameter, color: paintColor)
        case .statusDot:
            fillDot(diameter: Self.statusDotDiameter, color: paintColor)
        }
    }

    /// A filled dot, or the empty ring `TabConnectionDot` draws for a nil
    /// colour.
    private func fillDot(diameter: CGFloat, color: NSColor?) {
        let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        if let color {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            ring.stroke()
        }
    }
}
