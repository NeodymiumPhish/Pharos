import AppKit

// MARK: - Custom Cell View

class SchemaTreeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()

    /// Invoked when the user picks a sort mode on a partition-group row.
    var onPartitionSortChange: ((PartitionSortMode) -> Void)?
    private let sortControl = NSSegmentedControl(labels: ["Bound", "Name", "Size"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private var labelStackTrailingToCellConstraint: NSLayoutConstraint?
    private var labelStackTrailingToSortControlConstraint: NSLayoutConstraint?

    private static let importGlowAnimationKey = "pharosImportGlowPulse"

    /// Cached so we can re-render the secondary label when `backgroundStyle` changes
    /// (i.e. row goes from unselected to selected) without needing the node again.
    private var currentBaseSubtitle: String?
    private var currentImportingSuffix: String?

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: 13)
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .controlAccentColor
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 3
        badgeLabel.isHidden = true

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLabel.wantsLayer = true

        labelStack.orientation = .vertical
        labelStack.spacing = 0
        labelStack.alignment = .leading
        let primaryRow = NSStackView(views: [primaryLabel, badgeLabel])
        primaryRow.orientation = .horizontal
        primaryRow.spacing = 5
        primaryRow.alignment = .firstBaseline
        labelStack.addArrangedSubview(primaryRow)
        labelStack.addArrangedSubview(secondaryLabel)
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)

        let labelStackTrailingToCell = labelStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        labelStackTrailingToCellConstraint = labelStackTrailingToCell

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            labelStackTrailingToCell,
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(node: SchemaTreeNode) {
        iconView.image = node.icon
        iconView.contentTintColor = node.tintColor
        primaryLabel.stringValue = node.title

        if let badge = node.partitionBadge {
            badgeLabel.stringValue = " \(badge) "
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }

        if let sub = node.subtitle {
            applySecondaryText(base: sub, importing: node.importingSubtitle)
            secondaryLabel.isHidden = false
        } else {
            currentBaseSubtitle = nil
            currentImportingSuffix = nil
            secondaryLabel.isHidden = true
            removeImportGlow()
        }

        if case .loading = node.kind {
            primaryLabel.textColor = .tertiaryLabelColor
            primaryLabel.font = .systemFont(ofSize: 12)
        } else if case .partition(let info) = node.kind,
                  PartitionDisplay.boundSummary(info.partitionBound) == "DEFAULT" {
            primaryLabel.textColor = .secondaryLabelColor
            primaryLabel.font = .systemFont(ofSize: 13)
        } else {
            primaryLabel.textColor = .labelColor
            primaryLabel.font = .systemFont(ofSize: 13)
        }

        if case .partitionGroup = node.kind {
            if sortControl.superview == nil {
                sortControl.segmentStyle = .capsule
                sortControl.controlSize = .mini
                sortControl.translatesAutoresizingMaskIntoConstraints = false
                sortControl.target = self
                sortControl.action = #selector(sortChanged(_:))
                addSubview(sortControl)
                NSLayoutConstraint.activate([
                    sortControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                    sortControl.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
            sortControl.isHidden = false
            switch node.partitionSortMode {
            case .bound: sortControl.selectedSegment = 0
            case .name:  sortControl.selectedSegment = 1
            case .size:  sortControl.selectedSegment = 2
            }
            // Stop the labels short of the sort control instead of the cell's
            // trailing edge, so the "Partitions (N)" text never runs under it.
            labelStackTrailingToCellConstraint?.isActive = false
            if labelStackTrailingToSortControlConstraint == nil {
                labelStackTrailingToSortControlConstraint = labelStack.trailingAnchor.constraint(
                    lessThanOrEqualTo: sortControl.leadingAnchor, constant: -4)
            }
            labelStackTrailingToSortControlConstraint?.isActive = true
        } else {
            sortControl.isHidden = true
            labelStackTrailingToSortControlConstraint?.isActive = false
            labelStackTrailingToCellConstraint?.isActive = true
        }
    }

    @objc private func sortChanged(_ sender: NSSegmentedControl) {
        let mode: PartitionSortMode = [.bound, .name, .size][sender.selectedSegment]
        onPartitionSortChange?(mode)
    }

    /// Compose the secondary label's contents. When `importing` is non-nil, the
    /// suffix (" · Importing: N") is rendered in an accent or selection-contrasting
    /// color and the label gets a pulsing tinted shadow.
    private func applySecondaryText(base: String, importing: String?) {
        currentBaseSubtitle = base
        currentImportingSuffix = importing
        renderSecondaryText()
    }

    /// Render the secondary label using the currently cached strings + the cell's
    /// current `backgroundStyle`. When the row is selected with focus, the system
    /// uses the accent color as the highlight, so we switch the import suffix and
    /// glow to white for contrast.
    private func renderSecondaryText() {
        guard let base = currentBaseSubtitle else {
            secondaryLabel.stringValue = ""
            removeImportGlow()
            return
        }

        guard let importing = currentImportingSuffix else {
            secondaryLabel.stringValue = base
            secondaryLabel.textColor = (backgroundStyle == .emphasized)
                ? .alternateSelectedControlTextColor
                : .secondaryLabelColor
            removeImportGlow()
            return
        }

        let isEmphasized = backgroundStyle == .emphasized
        let baseColor: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        let importColor: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .controlAccentColor

        let attributed = NSMutableAttributedString(
            string: base,
            attributes: [
                .foregroundColor: baseColor,
                .font: NSFont.systemFont(ofSize: 10),
            ]
        )
        let separator = base.isEmpty || base == " " ? "" : " \u{00B7} "
        attributed.append(NSAttributedString(
            string: separator + importing,
            attributes: [
                .foregroundColor: importColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            ]
        ))
        secondaryLabel.attributedStringValue = attributed
        applyImportGlow(emphasized: isEmphasized)
    }

    private func applyImportGlow(emphasized: Bool) {
        guard let layer = secondaryLabel.layer else { return }
        // Pulse accent over normal background, white over the accent-colored selection.
        let glowColor: NSColor = emphasized ? .white : .controlAccentColor
        layer.shadowColor = glowColor.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        layer.masksToBounds = false

        // Re-add the animation if absent OR if the shadow color changed (animation
        // captures shadowOpacity but we want a fresh start when switching contexts).
        if layer.animation(forKey: Self.importGlowAnimationKey) == nil {
            let pulse = CABasicAnimation(keyPath: "shadowOpacity")
            pulse.fromValue = 0.25
            pulse.toValue = 0.75
            pulse.duration = 1.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.shadowOpacity = 0.5
            layer.add(pulse, forKey: Self.importGlowAnimationKey)
        }
    }

    private func removeImportGlow() {
        guard let layer = secondaryLabel.layer else { return }
        layer.removeAnimation(forKey: Self.importGlowAnimationKey)
        layer.shadowOpacity = 0
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Re-render so colors track selection state. (didSet only fires on change,
            // and we cache the strings so we don't need the node here.)
            renderSecondaryText()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentBaseSubtitle = nil
        currentImportingSuffix = nil
        removeImportGlow()
        badgeLabel.isHidden = true
        onPartitionSortChange = nil
        sortControl.isHidden = true
        labelStackTrailingToSortControlConstraint?.isActive = false
        labelStackTrailingToCellConstraint?.isActive = true
    }
}
