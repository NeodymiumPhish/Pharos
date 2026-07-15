import AppKit

/// One checklist row: a checkbox (the value) plus a right-aligned, subdued count
/// label. The owning view configures `checkbox` (title/state/target/action/tag)
/// and `countLabel.stringValue` per row and reuses instances by identifier.
final class FilterCheckRowView: NSView {

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        // Let the checkbox title truncate instead of pushing the count off-screen.
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(checkbox)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
