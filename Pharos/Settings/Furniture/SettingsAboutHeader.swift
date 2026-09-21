import AppKit

/// The hero at the top of a pane that opens with an identity rather than with
/// a row: the app icon, the app's name, and the version line under it, all
/// centred in a column. Settings ▸ About is the one pane that uses it.
///
/// It takes its image and its two strings, so it reads neither `Bundle.main`
/// nor the FFI and `scripts/test-settings-furniture.sh` measures it standalone.
/// `AboutSettingsPaneVC` supplies `NSApp.applicationIconImage` and `AppInfo`.
///
/// The version label is SELECTABLE. It is the one string a user is asked for
/// when they report a fault, and a label they cannot copy makes them retype it.
final class SettingsAboutHeader: NSView {

    let iconView = NSImageView()
    let nameLabel: NSTextField
    let versionLabel: NSTextField

    private let column = NSStackView()

    init(icon: NSImage?, name: String, versionLine: String) {
        nameLabel = NSTextField(labelWithString: name)
        versionLabel = NSTextField(labelWithString: versionLine)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let m = SettingsMetrics.self

        iconView.image = icon
        // `scaleProportionallyUpOrDown`, not `…Down`: the icon arrives at
        // whatever size the asset catalogue hands over, which for
        // `applicationIconImage` is larger than the box here — but a stand-in
        // smaller than 96pt must still fill it rather than float in the middle.
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // No image is not an empty 96pt box: a hidden arranged subview is
        // dropped from the stack's layout, so the hero closes up instead.
        iconView.isHidden = icon == nil
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // The name label says the same thing, so the image is decoration.
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityIdentifier("settings.about.icon")

        nameLabel.font = .systemFont(ofSize: m.aboutNameFontSize, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setAccessibilityIdentifier("settings.about.name")

        versionLabel.font = .systemFont(ofSize: m.aboutVersionFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.isSelectable = true
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.setAccessibilityIdentifier("settings.about.version")

        // The header spans the pane and must never be the thing that widens
        // it: a name or a version line longer than the pane truncates instead
        // of pushing the sidebar over. Both labels therefore yield, and the
        // pane's own width is what decides where they stop.
        for label in [nameLabel, versionLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = m.aboutHeaderSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(iconView)
        column.addArrangedSubview(nameLabel)
        column.addArrangedSubview(versionLabel)
        // The name sits closer to its version than to the icon.
        column.setCustomSpacing(m.aboutNameToVersionGap, after: nameLabel)
        addSubview(column)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: m.aboutIconSize),
            iconView.heightAnchor.constraint(equalToConstant: m.aboutIconSize),

            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: m.aboutHeaderInsetTop),
            bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: m.aboutHeaderInsetBottom),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            // The ceiling that makes the truncation happen. The stack's own
            // edge constraints are priority 250, the same as a label that has
            // been told to yield, so the tie was settled by the solver and a
            // long name ran off the header. A REQUIRED ceiling on each label
            // settles it here instead. `rowInsetH` is the side margin a row's
            // text keeps, so the hero's text stops in the same place.
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                                             constant: -2 * m.rowInsetH),
            versionLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                                                constant: -2 * m.rowInsetH),
        ])

        // Furniture, not a control: assistive technology reads the two labels.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsAboutHeader is built in code") }

    /// The strings, after the pane has read them again.
    func update(name: String, versionLine: String) {
        nameLabel.stringValue = name
        versionLabel.stringValue = versionLine
    }
}
