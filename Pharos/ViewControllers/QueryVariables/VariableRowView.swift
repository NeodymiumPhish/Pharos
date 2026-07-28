import AppKit

/// One row in the variables list. Read-only: the whole row is a click target
/// that drills in to the detail level. The layout mirrors the detail header —
/// `{{name}}` leading, type trailing — above a size caption and the value
/// preview, and the row renders the state it is handed rather than deciding it
/// (see `VariableSubstitutor.rowStates(in:referenced:)`).
final class VariableRowView: NSView {

    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let warningView = NSImageView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

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
        let problem = state?.problem
        let isShadowed = state?.duplication == .shadowed
        let named = !variable.name.isEmpty

        let nameTint: NSColor
        if !named {
            nameTint = .tertiaryLabelColor
        } else if problem != nil {
            nameTint = .systemRed
        } else if isShadowed {
            // Inert, not broken — drained of the indigo that means "this token
            // is live in your SQL".
            nameTint = .tertiaryLabelColor
        } else {
            nameTint = .systemIndigo
        }
        nameLabel.attributedStringValue = Self.tokenString(name: named ? variable.name : "name", tint: nameTint)

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
    private static func tokenString(name: String, tint: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let braces: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: tint.withAlphaComponent(0.55),
        ]
        let body: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "{{", attributes: braces))
        result.append(NSAttributedString(string: name, attributes: body))
        result.append(NSAttributedString(string: "}}", attributes: braces))
        return result
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
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
