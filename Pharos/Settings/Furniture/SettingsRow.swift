import AppKit

/// One row of a `SettingsGroupBox`: an optional icon, a title with an
/// optional caption beneath it, and a control — trailing by default, or below
/// the text for wide controls such as sliders and palette editors.
///
/// The text column yields and the control does not: a long caption WRAPS
/// inside the width left over rather than pushing the control off the plate
/// or widening the pane. `layout()` feeds the labels their available width,
/// which is what makes a wrapping `NSTextField` report a taller intrinsic
/// height instead of a wider one.
final class SettingsRow: NSView {

    enum ControlPlacement {
        /// The control sits at the trailing edge, vertically centred on the row.
        case trailing
        /// The control sits under the text column and spans the row's width.
        case below
    }

    let titleLabel: NSTextField
    let captionLabel: NSTextField
    let control: NSView?
    let iconView: NSImageView?

    var showsIcon: Bool { iconView != nil }

    /// The caption under the title. Empty or nil hides the label, so the row
    /// closes up to a single line.
    var caption: String? {
        didSet { applyCaption() }
    }

    /// Dims the text and disables the control. A control that is not an
    /// `NSControl` (a custom editor, say) is dimmed by alpha instead.
    var isEnabled: Bool = true {
        didSet { applyEnabled() }
    }

    private let textColumn = NSView()

    init(icon: NSImage? = nil,
         title: String,
         caption: String? = nil,
         control: NSView?,
         placement: ControlPlacement = .trailing,
         indent: CGFloat = 0) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        captionLabel = NSTextField(wrappingLabelWithString: caption ?? "")
        self.control = control
        self.caption = caption

        if let icon {
            let view = NSImageView(image: icon)
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleProportionallyDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            iconView = view
        } else {
            iconView = nil
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        captionLabel.font = .systemFont(ofSize: SettingsMetrics.captionFontSize)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.addSubview(titleLabel)
        textColumn.addSubview(captionLabel)
        addSubview(textColumn)

        if let iconView { addSubview(iconView) }
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            addSubview(control)
        }

        let m = SettingsMetrics.self
        var constraints: [NSLayoutConstraint] = []

        // Text column internals.
        constraints += [
            titleLabel.topAnchor.constraint(equalTo: textColumn.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textColumn.trailingAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: textColumn.trailingAnchor),
        ]
        captionGap = captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        captionBottom = textColumn.bottomAnchor.constraint(equalTo: captionLabel.bottomAnchor)
        titleBottom = textColumn.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor)
        constraints += [captionGap, captionBottom, titleBottom]

        // Leading: inset (+ indent), then icon, then text.
        let leadingInset = m.rowInsetH + indent
        if let iconView {
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
                iconView.widthAnchor.constraint(equalToConstant: m.rowIconSize),
                iconView.heightAnchor.constraint(equalToConstant: m.rowIconSize),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                textColumn.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: m.iconTextGap),
            ]
        } else {
            constraints.append(textColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset))
        }

        // Vertical: the text is centred, insets are minima, the row hugs its
        // content just above the default so the group box's stack sees a
        // definite height, and it never drops under the minimum.
        let hug = textColumn.topAnchor.constraint(equalTo: topAnchor, constant: m.rowInsetV)
        hug.priority = NSLayoutConstraint.Priority(rawValue: 251)
        constraints += [
            hug,
            textColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: m.rowInsetV),
            bottomAnchor.constraint(greaterThanOrEqualTo: textColumn.bottomAnchor, constant: m.rowInsetV),
            heightAnchor.constraint(greaterThanOrEqualToConstant: m.rowMinHeight),
        ]

        if let control {
            switch placement {
            case .trailing:
                constraints += [
                    textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
                    control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.rowInsetH),
                    control.leadingAnchor.constraint(equalTo: textColumn.trailingAnchor, constant: m.textControlGap),
                    control.centerYAnchor.constraint(equalTo: centerYAnchor),
                    control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: m.rowInsetV),
                    bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: m.rowInsetV),
                ]
            case .below:
                // Spans the row by preference; a control with a fixed width
                // of its own keeps it and stays leading-aligned.
                let span = control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.rowInsetH)
                span.priority = NSLayoutConstraint.Priority(rawValue: 749)
                constraints += [
                    textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.rowInsetH),
                    control.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
                    span,
                    control.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m.rowInsetH),
                    control.topAnchor.constraint(equalTo: textColumn.bottomAnchor, constant: 8),
                    bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: m.rowInsetV),
                ]
            }
        } else {
            constraints += [
                textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
                textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.rowInsetH),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        applyCaption()

        // The row is furniture; the control is what assistive technology
        // should land on, titled by the label and explained by the caption.
        setAccessibilityElement(false)
        control?.setAccessibilityTitleUIElement(titleLabel)
        if let caption, !caption.isEmpty { control?.setAccessibilityHelp(caption) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsRow is built in code") }

    private var captionGap: NSLayoutConstraint!
    private var captionBottom: NSLayoutConstraint!
    private var titleBottom: NSLayoutConstraint!

    /// Names the control for the AX tree and UI tests.
    func setControlIdentifier(_ id: String) {
        control?.setAccessibilityIdentifier(id)
    }

    override func layout() {
        super.layout()
        // AFTER the pass, so the column has its width. Feeding it to the
        // labels makes a long caption report a taller intrinsic size, not a
        // wider one — that is what stops it widening the pane, and it is also
        // what `fittingSize` sees (a wrapping field with no preferred width
        // reports its whole single-line width there). A change invalidates
        // the intrinsic size, which schedules the next pass.
        let width = textColumn.bounds.width
        guard width > 0 else { return }
        if titleLabel.preferredMaxLayoutWidth != width { titleLabel.preferredMaxLayoutWidth = width }
        if captionLabel.preferredMaxLayoutWidth != width { captionLabel.preferredMaxLayoutWidth = width }
    }

    private func applyCaption() {
        let text = caption ?? ""
        captionLabel.stringValue = text
        let hidden = text.isEmpty
        captionLabel.isHidden = hidden
        captionGap.isActive = !hidden
        captionBottom.isActive = !hidden
        titleBottom.isActive = hidden
        control?.setAccessibilityHelp(hidden ? nil : text)
    }

    private func applyEnabled() {
        titleLabel.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        captionLabel.textColor = isEnabled ? .secondaryLabelColor : .quaternaryLabelColor
        iconView?.contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        if let control = control as? NSControl {
            control.isEnabled = isEnabled
        } else if let control {
            control.alphaValue = isEnabled ? 1 : 0.5
        }
    }
}
