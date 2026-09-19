import AppKit

/// The row at the top of the detail pane: Back / Forward chevrons and the
/// pane's title in bold, as Xcode's Settings window has. It lives under the
/// transparent title bar, so it also drags the window.
final class SettingsDetailHeaderView: NSView {

    var onNavigate: ((SettingsWindow.NavigationDirection) -> Void)?

    private let navControl = NSSegmentedControl()
    private let titleLabel = NSTextField(labelWithString: "")

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        navControl.segmentCount = 2
        navControl.trackingMode = .momentary
        navControl.segmentStyle = .automatic
        navControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back")), forSegment: 0)
        navControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Forward")), forSegment: 1)
        navControl.setToolTip(String(localized: "Back"), forSegment: 0)
        navControl.setToolTip(String(localized: "Forward"), forSegment: 1)
        navControl.setWidth(28, forSegment: 0)
        navControl.setWidth(28, forSegment: 1)
        navControl.target = self
        navControl.action = #selector(navPressed)
        navControl.setAccessibilityIdentifier("settings.nav")
        navControl.setAccessibilityLabel(String(localized: "Navigation"))
        navControl.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: SettingsMetrics.navTitleFontSize, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("settings.title")
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(navControl)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.headerHeight),
            navControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            navControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: navControl.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    var title: String { titleLabel.stringValue }
    var canGoBack: Bool { navControl.isEnabled(forSegment: 0) }
    var canGoForward: Bool { navControl.isEnabled(forSegment: 1) }
    var navigationControl: NSSegmentedControl { navControl }

    func update(title: String, canGoBack: Bool, canGoForward: Bool) {
        titleLabel.stringValue = title
        navControl.setEnabled(canGoBack, forSegment: 0)
        navControl.setEnabled(canGoForward, forSegment: 1)
    }

    @objc private func navPressed() {
        onNavigate?(navControl.selectedSegment == 0 ? .back : .forward)
    }
}
