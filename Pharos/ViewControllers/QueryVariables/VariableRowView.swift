import AppKit

/// Decorative: the row itself is the click target, and a label that swallowed
/// hit-testing would make the row unopenable and block its tooltip.
private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One row in the variables list. Read-only: the whole row is a click target
/// that drills in to the detail level. The layout mirrors the detail header —
/// `{{name}}` leading, type trailing — above a size caption and the value
/// preview, and the row renders the state it is handed rather than deciding it
/// (see `VariableSubstitutor.rowStates(in:referenced:)`).
final class VariableRowView: NSView {

    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?

    private let nameLabel = PassthroughTextField(labelWithString: "")
    private let warningView = PassthroughImageView()
    private let typeLabel = PassthroughTextField(labelWithString: "")
    private let captionLabel = PassthroughTextField(labelWithString: "")
    private let valueLabel = PassthroughTextField(labelWithString: "")
    private let chevronView = PassthroughImageView()

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    private var trackingArea: NSTrackingArea?

    /// The last content handed to `configure`, replayed on an effective-appearance
    /// change. The name label's attributed string bakes in resolved colours at
    /// build time, so it does not follow a light/dark switch on its own —
    /// rebuilding it from the same inputs is simpler than trying to keep a
    /// second, always-dynamic copy in sync.
    private var lastConfigured: (variable: QueryVariable, state: VariableSubstitutor.RowState?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Content

    /// Render `variable` in the state it was handed. `state` is nil when the row
    /// has nothing to report; the caller decides both what counts as a problem
    /// and what counts as shadowed, this view only draws the outcome.
    ///
    /// Three presentations, and they compose: a shadowed row is inert so it dims
    /// and says so in place of its size caption; a problem row goes red; the
    /// effective definition of a duplicated name (`.overriding`) looks completely
    /// normal here, because it works — its "also defined above" note belongs in
    /// the detail level, where the name is edited.
    func configure(with variable: QueryVariable, state: VariableSubstitutor.RowState?) {
        lastConfigured = (variable, state)

        let problem = state?.problem
        let isShadowed = state?.duplication == .shadowed
        let named = !variable.name.isEmpty

        // Brace colour is a semantic pair with the body tint, not derived from
        // it: `.tertiaryLabelColor`'s own alpha (~0.26) is already lower than
        // 0.55, so multiplying it by 0.55 would make the braces *more* opaque
        // than the name they're meant to recede behind. `.systemIndigo` and
        // `.systemRed` are opaque, so deriving from them is fine.
        let nameTint: NSColor
        let braceColor: NSColor
        if !named {
            nameTint = .tertiaryLabelColor
            braceColor = .quaternaryLabelColor
        } else if problem != nil {
            nameTint = .systemRed
            braceColor = .systemRed.withAlphaComponent(0.55)
        } else if isShadowed {
            // Inert, not broken — drained of the indigo that means "this token
            // is live in your SQL".
            nameTint = .tertiaryLabelColor
            braceColor = .quaternaryLabelColor
        } else {
            nameTint = .systemIndigo
            braceColor = .systemIndigo.withAlphaComponent(0.55)
        }
        nameLabel.attributedStringValue = Self.tokenString(
            name: named ? variable.name : "name", tint: nameTint, braceColor: braceColor)

        typeLabel.stringValue = variable.type.displayName
        typeLabel.textColor = isShadowed ? .tertiaryLabelColor : .secondaryLabelColor

        // The size of a value that never reaches the query is not the useful
        // thing to say about it, so the caption slot carries the reason instead.
        captionLabel.stringValue = isShadowed
            ? "not used — redefined below"
            : VariableValuePreview.caption(for: variable.value)

        if variable.value.isEmpty {
            valueLabel.stringValue = "no value"
            valueLabel.font = Self.italicPreviewFont
            valueLabel.textColor = problem != nil ? .systemRed : .tertiaryLabelColor
        } else {
            valueLabel.stringValue = VariableValuePreview.snippet(for: variable.value)
            valueLabel.font = Self.previewFont
            valueLabel.textColor = isShadowed ? .tertiaryLabelColor : .secondaryLabelColor
        }

        // No glyph for shadowing: it is information, not a failure.
        warningView.isHidden = problem == nil
        toolTip = problem?.message ?? (isShadowed
            ? "Another variable with this name is defined further down, and that one is used."
            : nil)

        setAccessibilityRole(.button)
        setAccessibilityLabel("\(named ? variable.name : "unnamed variable"), \(typeLabel.stringValue), \(captionLabel.stringValue)")
    }

    /// The attributed name string bakes in resolved colours at configure time,
    /// so it does not follow a light/dark switch on its own — replay the last
    /// configuration to rebuild it under the new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let last = lastConfigured else { return }
        configure(with: last.variable, state: last.state)
    }

    // MARK: - Layout

    private static let previewFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// Italic variant for the `no value` placeholder. `NSFontManager` is used
    /// rather than a descriptor dance because the monospaced system font has no
    /// italic face to resolve by name.
    private static let italicPreviewFont = NSFontManager.shared.convert(
        NSFont.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)

    private func buildLayout() {
        nameLabel.lineBreakMode = .byTruncatingTail

        typeLabel.font = .systemFont(ofSize: 9)
        typeLabel.textColor = .secondaryLabelColor

        captionLabel.font = .systemFont(ofSize: 9)
        captionLabel.textColor = .tertiaryLabelColor

        valueLabel.font = Self.previewFont
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingTail

        let smallSymbol = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        warningView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "This variable will break the query"
        )?.withSymbolConfiguration(smallSymbol)
        warningView.contentTintColor = .systemRed
        warningView.isHidden = true

        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(smallSymbol)
        chevronView.contentTintColor = .tertiaryLabelColor
        // Without this, the required leading/trailing pins on both sides of
        // this view make it — not the text next to it — absorb all the row's
        // slack width, and NSImageView centres its small glyph inside however
        // much space it is given, so the chevron drifts away from the edge.
        chevronView.setContentHuggingPriority(.required, for: .horizontal)

        // A stack collapses `warningView` out of the layout while it is hidden,
        // so the type caption does not sit permanently indented.
        let topRight = NSStackView(views: [warningView, typeLabel])
        topRight.orientation = .horizontal
        topRight.spacing = 3
        topRight.alignment = .centerY

        for subview in [nameLabel, topRight, captionLabel, valueLabel, chevronView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRight.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: topRight.leadingAnchor, constant: -6),

            topRight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            topRight.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            captionLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            captionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            valueLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -6),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevronView.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),
        ])
    }

    /// `{{name}}` with the braces dimmed, matching how the editor paints tokens.
    /// Truncation is carried on the string's own paragraph style rather than
    /// left to `nameLabel.lineBreakMode`: `NSTextField.attributedStringValue`
    /// lets the string's own style win over the control's property, so without
    /// this a long name wraps instead of truncating and the row's height grows.
    private static func tokenString(name: String, tint: NSColor, braceColor: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let braces: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: braceColor, .paragraphStyle: paragraph,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: tint, .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "{{", attributes: braces))
        result.append(NSAttributedString(string: name, attributes: body))
        result.append(NSAttributedString(string: "}}", attributes: braces))
        return result
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            // `.inVisibleRect` clips the tracked rect to what is actually on
            // screen inside an enclosing clip view — without it, a row that
            // scrolls out from under a fixed header still keeps a tracking
            // rect covering its full (offscreen) bounds and can receive a
            // `mouseEntered` for a position it no longer occupies, leaving the
            // hover highlight stuck on a row that isn't under the pointer.
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        bounds.fill()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// Right-click offers Delete so a variable can be removed without drilling in.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func deleteSelected() { onDelete?() }
}
