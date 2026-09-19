import AppKit

/// The one row a list-style group box shows when it has nothing to list.
final class SettingsEmptyRow: NSView {

    let label: NSTextField

    init(text: String = String(localized: "No Items")) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.rowMinHeight),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: SettingsMetrics.rowInsetH),
            trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: SettingsMetrics.rowInsetH),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsEmptyRow is built in code") }
}
