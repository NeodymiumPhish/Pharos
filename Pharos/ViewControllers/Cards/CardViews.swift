import AppKit

// The parts of one query card on screen: the coloured card itself, its name
// row, the read-only preview a card shows while it has no live editor, and
// the folded row of a query's older versions.

/// The card colours. Red, orange and green are left out: they mean error,
/// edited and success here (HIG, Color). Brown is left out for contrast.
enum CardPalette {
    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemIndigo, .systemMint, .systemCyan]

    static func color(_ index: Int?) -> NSColor? {
        index.map { colors[(($0 % colors.count) + colors.count) % colors.count] }
    }
}

// MARK: - Name row

/// A card's name row: name, version, lock, state badge, the large View Results
/// button, Run, Run and Replace, Cancel and the ⋯ menu. Shows a
/// `CardPresentation`; every click goes out through a closure.
final class CardHeaderView: NSView {
    static let height: CGFloat = 34

    var onViewResults: (() -> Void)?
    var onRun: (() -> Void)?
    var onRunReplace: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRename: (() -> Void)?
    /// The ⋯ menu, built fresh by the owner each time it opens.
    var menuProvider: (() -> NSMenu)?

    private let disclosure = NSButton()
    let nameLabel = NSTextField(labelWithString: "")
    private let versionChip = ChipLabel()
    private let lockImage = NSImageView()
    private let badge = ChipLabel()
    let metaLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let resultsButton = NSButton()
    let runButton = NSButton()
    let runReplaceButton = NSButton()
    let cancelButton = NSButton()
    let moreButton = NSButton()
    private var cardColor: NSColor = .controlAccentColor
    var onToggleCollapse: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    private func build() {
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.title = ""
        disclosure.state = .on
        disclosure.target = self
        disclosure.action = #selector(toggleCollapse)
        disclosure.setAccessibilityLabel(String(localized: "Show SQL"))

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        lockImage.image = symbol("lock.fill", String(localized: "Locked"))
        lockImage.contentTintColor = .secondaryLabelColor
        lockImage.toolTip = String(localized: "Locked: this version keeps the SQL its results came from. Use Edit as New Card to change it.")

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        resultsButton.bezelStyle = .push
        resultsButton.controlSize = .regular
        resultsButton.target = self
        resultsButton.action = #selector(viewResults)
        resultsButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        for (button, image, label, action) in [
            (runButton, "play.fill", String(localized: "Run"), #selector(run)),
            (runReplaceButton, "arrow.triangle.2.circlepath", String(localized: "Run and Replace Results"), #selector(runReplace)),
            (cancelButton, "stop.fill", String(localized: "Cancel"), #selector(cancel)),
        ] {
            button.bezelStyle = .push
            button.image = symbol(image, label)
            button.imagePosition = .imageOnly
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        runButton.toolTip = String(localized: "Run (⌘↩)")
        runReplaceButton.toolTip = String(localized: "Run and Replace Results (⇧⌘↩): replace this card's results instead of keeping them as a locked version")
        cancelButton.contentTintColor = .systemRed

        moreButton.bezelStyle = .push
        moreButton.image = symbol("ellipsis", String(localized: "More"))
        moreButton.imagePosition = .imageOnly
        moreButton.setAccessibilityLabel(String(localized: "More"))
        moreButton.target = self
        moreButton.action = #selector(showMenu)

        let leading = NSStackView(views: [disclosure, nameLabel, versionChip, lockImage, badge, spinner, metaLabel])
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = NSStackView(views: [resultsButton, runButton, runReplaceButton, cancelButton, moreButton])
        trailing.orientation = .horizontal
        trailing.spacing = 4
        trailing.alignment = .centerY
        trailing.setHuggingPriority(.required, for: .horizontal)
        for v in [leading, trailing] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
        ])
    }

    /// Show `p` for a card drawn in `color`.
    func apply(_ p: CardPresentation, color: NSColor?, isCollapsed: Bool, meta: String) {
        cardColor = color ?? .controlAccentColor
        nameLabel.stringValue = p.title
        nameLabel.textColor = p.titleIsPlaceholder ? .secondaryLabelColor : .labelColor
        nameLabel.font = p.titleIsPlaceholder
            ? NSFontManager.shared.convert(.systemFont(ofSize: 13, weight: .medium), toHaveTrait: .italicFontMask)
            : .systemFont(ofSize: 13, weight: .semibold)
        versionChip.isHidden = p.versionChip == nil
        versionChip.set(text: p.versionChip ?? "", tone: .neutral)
        lockImage.isHidden = !p.isLocked
        if let b = p.badge {
            badge.isHidden = false
            badge.set(text: b.text, tone: b.tone)
        } else {
            badge.isHidden = true
        }
        metaLabel.stringValue = meta
        metaLabel.isHidden = meta.isEmpty
        if p.state == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        if let rb = p.resultsButton {
            resultsButton.isHidden = false
            let title = [rb.title, rb.detail].compactMap { $0 }.joined(separator: " · ")
            let tint: NSColor = rb.isError ? .systemRed : cardColor
            resultsButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: rb.isShowing ? NSColor.white : tint,
            ])
            // Only the card whose results are on screen gets the filled
            // button: one prominent button at a time (HIG, Buttons).
            resultsButton.bezelColor = rb.isShowing ? tint : nil
            resultsButton.setAccessibilityLabel(title)
            resultsButton.setAccessibilityValue(rb.isShowing ? String(localized: "shown") : nil)
        } else {
            resultsButton.isHidden = true
        }
        runButton.isHidden = !p.canRun
        runReplaceButton.isHidden = !p.showsRunAndReplace
        cancelButton.isHidden = !p.showsCancel
        disclosure.state = isCollapsed ? .off : .on
        disclosure.setAccessibilityLabel(isCollapsed ? String(localized: "Show SQL") : String(localized: "Hide SQL"))
    }

    /// Accessibility identifiers for card `n` (1-based).
    func setIdentifiers(prefix: String) {
        setAccessibilityIdentifier("\(prefix).header")
        nameLabel.setAccessibilityIdentifier("\(prefix).name")
        resultsButton.setAccessibilityIdentifier("\(prefix).viewResults")
        runButton.setAccessibilityIdentifier("\(prefix).run")
        runReplaceButton.setAccessibilityIdentifier("\(prefix).runReplace")
        cancelButton.setAccessibilityIdentifier("\(prefix).cancel")
        moreButton.setAccessibilityIdentifier("\(prefix).more")
    }

    @objc private func viewResults() { onViewResults?() }
    @objc private func run() { onRun?() }
    @objc private func runReplace() { onRunReplace?() }
    @objc private func cancel() { onCancel?() }
    @objc private func toggleCollapse() { onToggleCollapse?() }

    @objc private func showMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 2), in: moreButton)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, nameLabel.frame.insetBy(dx: -4, dy: -4)
            .contains(convert(event.locationInWindow, from: nil).applying(.identity)) {
            onRename?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// A small rounded label: the version chip and the state badge.
final class ChipLabel: NSTextField {
    private var tone: CardPresentation.Tone = .neutral

    convenience init() {
        self.init(labelWithString: "")
        font = .systemFont(ofSize: 10.5, weight: .semibold)
        alignment = .center
        drawsBackground = false
        isBezeled = false
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    func set(text: String, tone: CardPresentation.Tone) {
        stringValue = text
        self.tone = tone
        switch tone {
        case .neutral: textColor = .secondaryLabelColor
        case .caution: textColor = .systemOrange
        case .error: textColor = .systemRed
        }
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 12, height: max(s.height + 4, 18))
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        switch tone {
        case .neutral: fill = .quaternaryLabelColor
        case .caution: fill = NSColor.systemOrange.withAlphaComponent(0.16)
        case .error: fill = NSColor.systemRed.withAlphaComponent(0.14)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = attributedStringValue
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Card

/// One card: a rounded panel with a colour stripe, the name row, and the body
/// (a live editor or a preview). Flipped, so the name row is at the top.
final class CardView: NSView {
    static let cornerRadius: CGFloat = 9
    static let stripeWidth: CGFloat = 4

    let cardId: String
    let header = CardHeaderView()
    /// The live editor or the preview, below the name row.
    private(set) var body: NSView?
    var color: NSColor? { didSet { needsDisplay = true } }
    var isFocused = false { didSet { if oldValue != isFocused { needsDisplay = true } } }
    var isDisplayed = false { didSet { if oldValue != isDisplayed { needsDisplay = true } } }
    var isLocked = false { didSet { if oldValue != isLocked { needsDisplay = true } } }
    var isCollapsed = false { didSet { needsLayout = true } }
    /// Height of the body when shown.
    var bodyHeight: CGFloat = 0 { didSet { needsLayout = true } }

    init(cardId: String) {
        self.cardId = cardId
        super.init(frame: .zero)
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    /// The height the card needs.
    var fittingHeight: CGFloat {
        CardHeaderView.height + (isCollapsed ? 0 : bodyHeight + 1)
    }

    func setBody(_ view: NSView?) {
        guard view !== body else { return }
        body?.removeFromSuperview()
        body = view
        if let view { addSubview(view) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: Self.stripeWidth, y: 0, width: bounds.width - Self.stripeWidth, height: CardHeaderView.height)
        body?.isHidden = isCollapsed
        body?.frame = NSRect(x: Self.stripeWidth, y: CardHeaderView.height + 1,
                             width: max(0, bounds.width - Self.stripeWidth - 1), height: max(0, bodyHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        (isLocked ? NSColor.underPageBackgroundColor : NSColor.textBackgroundColor).setFill()
        path.fill()

        // The stripe: the card's colour, or a neutral one for a card that has
        // never succeeded.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (color ?? .separatorColor).setFill()
        NSRect(x: 0, y: 0, width: Self.stripeWidth, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        if !isCollapsed {
            NSColor.separatorColor.setFill()
            NSRect(x: Self.stripeWidth, y: CardHeaderView.height, width: bounds.width - Self.stripeWidth, height: 1).fill()
        }

        // The focus ring (where you type) and the results outline (whose
        // results are on screen) look different, so both can show at once
        // (HIG, Focus and selection).
        if isDisplayed {
            (color ?? .controlAccentColor).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            outline.lineWidth = 2
            outline.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if isFocused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: isDisplayed ? 3 : 1.5, dy: isDisplayed ? 3 : 1.5),
                                    xRadius: Self.cornerRadius - 1, yRadius: Self.cornerRadius - 1)
            ring.lineWidth = isDisplayed ? 1.5 : 2.5
            ring.stroke()
        }
    }
}

// MARK: - Preview

/// What a card shows while it has no live editor: its SQL, coloured, at the
/// editor's font and insets, so turning it into an editor moves nothing. A
/// click asks for the live editor at the clicked character.
final class CardPreviewView: NSView {
    var onActivate: ((_ characterIndex: Int) -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
    private var gutterWidth: CGFloat = 0
    private var lineCount = 1
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var wraps = false
    static let inset = NSSize(width: 4, height: 8)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    func show(sql: String, font: NSFont, theme: SQLTheme, wraps: Bool, showsLineNumbers: Bool, variableNames: Set<String>) {
        self.font = font
        self.wraps = wraps
        storage.setAttributedString(SQLSyntaxHighlighter.attributedString(
            for: sql, font: font, baseColor: .textColor, theme: theme, variableNames: variableNames))
        lineCount = max(1, sql.components(separatedBy: "\n").count)
        if showsLineNumbers {
            let digits = max(2, String(lineCount).count)
            let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            gutterWidth = ceil(CGFloat(digits) * digitWidth + 22)
        } else {
            gutterWidth = 0
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The height this text needs at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        container.size = NSSize(width: wraps ? max(10, width - gutterWidth - Self.inset.width * 2) : CGFloat.greatestFiniteMagnitude,
                                height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let line = layoutManager.defaultLineHeight(for: font)
        return ceil(max(layoutManager.usedRect(for: container).height, line) + Self.inset.height * 2) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = height(forWidth: bounds.width)
        let origin = NSPoint(x: gutterWidth + Self.inset.width, y: Self.inset.height)
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        guard gutterWidth > 0 else { return }
        // Line numbers, in the gutter's place.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var line = 1
        var index = 0
        let text = storage.string as NSString
        while index <= text.length && line <= lineCount {
            let glyph = layoutManager.numberOfGlyphs == 0 ? 0 : layoutManager.glyphIndexForCharacter(at: min(index, max(0, text.length - 1)))
            var rect = layoutManager.numberOfGlyphs == 0 ? .zero : layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if index >= text.length && text.length > 0 && text.hasSuffix("\n") { rect = layoutManager.extraLineFragmentRect }
            let number = "\(line)" as NSString
            let size = number.size(withAttributes: attrs)
            number.draw(at: NSPoint(x: gutterWidth - size.width - 10, y: origin.y + rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
            let next = text.range(of: "\n", range: NSRange(location: index, length: text.length - index))
            if next.location == NSNotFound { break }
            index = next.location + 1
            line += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: p.x - gutterWidth - Self.inset.width, y: p.y - Self.inset.height)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: inText, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        onActivate?(index + (fraction > 0.5 ? 1 : 0))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

// MARK: - Folded versions

/// The row that stands for a query's older versions: "3 earlier versions of
/// Active users", with a chip per version. A click on the row opens them; a
/// click on a chip shows that version's results.
final class VersionGroupView: NSView {
    static let height: CGFloat = 30

    var onExpand: (() -> Void)?
    var onShowVersion: ((_ cardId: String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let chips = NSStackView()
    private var cardIds: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let disclosure = NSButton()
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.title = ""
        disclosure.state = .off
        disclosure.target = self
        disclosure.action = #selector(expand)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        chips.orientation = .horizontal
        chips.spacing = 4
        let row = NSStackView(views: [disclosure, label, NSView(), chips])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func show(name: String, versions: [(cardId: String, version: Int)]) {
        cardIds = versions.map(\.cardId)
        let n = versions.count
        label.stringValue = n == 1
            ? String(localized: "1 earlier version of \(name)")
            : String(localized: "\(n) earlier versions of \(name)")
        setAccessibilityLabel(label.stringValue)
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, v) in versions.enumerated() {
            let chip = NSButton(title: "v\(v.version)", target: self, action: #selector(chipClicked(_:)))
            chip.bezelStyle = .inline
            chip.controlSize = .small
            chip.tag = i
            chip.toolTip = String(localized: "Show the results of version \(v.version)")
            chips.addArrangedSubview(chip)
        }
    }

    @objc private func expand() { onExpand?() }

    @objc private func chipClicked(_ sender: NSButton) {
        guard sender.tag < cardIds.count else { return }
        onShowVersion?(cardIds[sender.tag])
    }

    override func mouseDown(with event: NSEvent) { onExpand?() }

    override func accessibilityPerformPress() -> Bool {
        onExpand?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.underPageBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

/// "New query card", at the end of the stack.
final class AddCardButton: NSButton {
    static let height: CGFloat = 32

    convenience init(target: AnyObject, action: Selector) {
        self.init(title: String(localized: "New Query Card"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
                  target: target, action: action)
        bezelStyle = .push
        isBordered = false
        imagePosition = .imageLeading
        contentTintColor = .secondaryLabelColor
        toolTip = String(localized: "New Query Card (⌃⌘N)")
        setAccessibilityIdentifier("editor.cards.add")
        // The symbol's own name ("add") would otherwise be the description.
        setAccessibilityLabel(String(localized: "New Query Card"))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor.separatorColor.setStroke()
        path.stroke()
        super.draw(dirtyRect)
    }
}
