import AppKit

// MARK: - Custom Cell View

/// One row of the schema browser: icon, name, and — trailing on the SAME line
/// — the short caption (row count, column type, partition bound) plus the
/// RANGE/LIST/HASH pill for a partitioned parent.
///
/// One line, not two. The outline view is a system source list now, so its rows
/// are the height the user chose in System Settings > Appearance > Sidebar icon
/// size; a stacked title-over-subtitle cell does not fit inside that height and
/// cannot ask for more. What the caption can no longer spell out — a table's
/// exact row count and its size on disk — is in the row's tooltip and in the
/// Inspector, both of which have the room for it.
class SchemaTreeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    /// Active when a partition badge is shown: the caption stops before the badge.
    private var secondaryTrailingToBadge: NSLayoutConstraint!
    /// Active when no badge: the caption extends to the cell's trailing edge.
    private var secondaryTrailingToCell: NSLayoutConstraint!
    /// Active only while the caption has something to say — a zero-text caption
    /// must not reserve its floor width and truncate the name for nothing.
    private var secondaryMinimumWidth: NSLayoutConstraint!

    /// The caption never gives up more than this. A column's row is the only
    /// place its type appears in the tree, and "timestamp w…" still says more
    /// than an empty trailing gap; the NAME truncates first instead, because a
    /// name is recognisable from its head.
    static let minimumCaptionWidth: CGFloat = 60

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
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 250. The caption (249, below) is squeezed to its floor before this
        // one gives up a character.
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Handing the label to NSTableCellView lets the table set its font from
        // the row size style, which is the whole point of a source list: no
        // hard-coded point size here fights the user's sidebar setting.
        textField = primaryLabel

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 3
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 11)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .right
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(
            .init(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        secondaryLabel.wantsLayer = true

        addSubview(iconView)
        addSubview(primaryLabel)
        addSubview(secondaryLabel)
        addSubview(badgeLabel)

        secondaryTrailingToBadge = secondaryLabel.trailingAnchor.constraint(
            equalTo: badgeLabel.leadingAnchor, constant: -6)
        secondaryTrailingToCell = secondaryLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -4)
        secondaryMinimumWidth = secondaryLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumCaptionWidth)
        // Below required, so an absurdly narrow sidebar collapses the caption
        // rather than breaking the row apart.
        secondaryMinimumWidth.priority = .init(rawValue: 900)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            primaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: primaryLabel.trailingAnchor, constant: 8),
            secondaryLabel.firstBaselineAnchor.constraint(equalTo: primaryLabel.firstBaselineAnchor),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Default (no badge) trailing constraint; configure() swaps as needed.
        secondaryTrailingToCell.isActive = true
    }

    func configure(node: SchemaTreeNode) {
        iconView.image = node.icon
        iconView.contentTintColor = node.tintColor
        primaryLabel.stringValue = node.title
        // The exact row count and the size on disk no longer fit on the row;
        // this is where they went.
        toolTip = node.tooltip

        if let badge = node.partitionBadge {
            badgeLabel.stringValue = " \(badge) "
            badgeLabel.isHidden = false
            secondaryTrailingToCell.isActive = false
            secondaryTrailingToBadge.isActive = true
            renderBadge()
        } else {
            badgeLabel.isHidden = true
            secondaryTrailingToBadge.isActive = false
            secondaryTrailingToCell.isActive = true
        }

        // The " " sentinel that reserved the second line in the old two-line
        // cell means nothing here — a caption with no characters is no caption.
        let sub = node.subtitle
        let hasCaption = !(sub ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || node.importingSubtitle != nil
        if hasCaption, let sub {
            applySecondaryText(base: sub, importing: node.importingSubtitle)
            secondaryLabel.isHidden = false
            secondaryMinimumWidth.isActive = true
        } else {
            currentBaseSubtitle = nil
            currentImportingSuffix = nil
            secondaryLabel.stringValue = ""
            secondaryLabel.isHidden = true
            secondaryMinimumWidth.isActive = false
            removeImportGlow()
        }

        if case .loading = node.kind {
            primaryLabel.textColor = .tertiaryLabelColor
        } else if case .partition(let info) = node.kind,
                  PartitionDisplay.boundSummary(info.partitionBound) == "DEFAULT" {
            primaryLabel.textColor = .secondaryLabelColor
        } else {
            primaryLabel.textColor = .labelColor
        }
    }

    /// Colour the badge as an accent-tinted pill, switching to a light-on-selection
    /// treatment when the row is selected+focused (backgroundStyle == .emphasized).
    private func renderBadge() {
        guard !badgeLabel.isHidden else { return }
        if backgroundStyle == .emphasized {
            badgeLabel.textColor = .alternateSelectedControlTextColor
            badgeLabel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        } else {
            badgeLabel.textColor = .controlAccentColor
            badgeLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }
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
                .font: NSFont.systemFont(ofSize: 11),
            ]
        )
        let separator = base.isEmpty || base == " " ? "" : " \u{00B7} "
        attributed.append(NSAttributedString(
            string: separator + importing,
            attributes: [
                .foregroundColor: importColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
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
            renderBadge()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentBaseSubtitle = nil
        currentImportingSuffix = nil
        removeImportGlow()
        toolTip = nil
        badgeLabel.isHidden = true
        badgeLabel.stringValue = ""
        secondaryTrailingToBadge.isActive = false
        secondaryTrailingToCell.isActive = true
    }

    // MARK: - Test seams

    /// `scripts/test-schema-cell-one-line.sh` measures these directly: a
    /// rendered screenshot cannot tell a truncated label from a short one.
    var nameLabelForTesting: NSTextField { primaryLabel }
    var captionLabelForTesting: NSTextField { secondaryLabel }
    var badgeLabelForTesting: NSTextField { badgeLabel }
    var iconViewForTesting: NSImageView { iconView }
}
