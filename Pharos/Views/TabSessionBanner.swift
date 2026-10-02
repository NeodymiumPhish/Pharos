import AppKit

/// The row above a tab's cards while its connection holds an open
/// transaction, a failed one, or was reset. Commit and Roll Back act on the
/// tab's connection; a reset notice is dismissed with OK.
///
/// It is a status bar, not an alert (Apple HIG, Alerts: keep alerts for
/// information the user must act on now). An open transaction is a normal
/// working state, so the banner tells, and the buttons stay out of the way.
final class TabSessionBanner: NSView {
    static let height: CGFloat = 30

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let separator = NSBox()

    var onAction: ((TabSessionBannerAction) -> Void)?
    private(set) var state: TabSessionBannerState?
    private var actionButtons: [(TabSessionBannerAction, NSButton)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("editor.sessionBanner")

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("editor.sessionBanner.message")
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 6
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        addSubview(buttons)
        addSubview(separator)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show a state; nil hides the banner (the host gives it no height).
    func apply(_ state: TabSessionBannerState?) {
        let actionsChanged = state?.actions != self.state?.actions
        self.state = state
        isHidden = state == nil
        guard let state else { return }
        label.stringValue = state.message
        label.toolTip = state.message
        setAccessibilityLabel(state.message)
        let (symbol, tint): (String, NSColor) = switch state {
        case .transaction: ("arrow.triangle.branch", .systemOrange)
        case .failed: ("exclamationmark.octagon.fill", .systemRed)
        case .reset: ("arrow.clockwise.circle", .secondaryLabelColor)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        if actionsChanged { rebuildButtons(state.actions) }
        needsDisplay = true
    }

    /// The button for an action, for tests and VoiceOver checks.
    func button(for action: TabSessionBannerAction) -> NSButton? {
        actionButtons.first { $0.0 == action }?.1
    }

    private func rebuildButtons(_ actions: [TabSessionBannerAction]) {
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        actionButtons = actions.map { action in
            let button = NSButton(title: action.title, target: self, action: #selector(pressed(_:)))
            button.controlSize = .small
            button.bezelStyle = .push
            switch action {
            case .commit: button.setAccessibilityIdentifier("editor.sessionBanner.commit")
            case .rollBack: button.setAccessibilityIdentifier("editor.sessionBanner.rollBack")
            case .dismiss: button.setAccessibilityIdentifier("editor.sessionBanner.dismiss")
            }
            buttons.addArrangedSubview(button)
            return (action, button)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let action = actionButtons.first(where: { $0.1 === sender })?.0 else { return }
        onAction?(action)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let tint: NSColor = switch state {
        case .transaction: .systemOrange
        case .failed: .systemRed
        case .reset: .secondaryLabelColor
        }
        tint.withAlphaComponent(0.10).setFill()
        bounds.fill()
    }
}
