import AppKit

/// One line across the top of the results area saying that the last run failed.
///
/// It replaces the sheet for the FIRST unread failure on the active tab. A sheet
/// stops the app to say something the user can usually read in a line, and the
/// query they were writing is right behind it; a banner says the same thing and
/// leaves the editor usable. The sheet is still one click away, and still opens
/// by itself once a second failure is waiting — at that point the log, not the
/// line, is what the user needs.
///
/// Nothing here decides when to appear: `QueryErrorPresenter` does, and the
/// owner calls `show(_:)` / `hide()`.
final class QueryErrorBanner: NSView {

    /// Height when shown. The owner drives the height constraint, so this is
    /// the one number both sides agree on.
    static let height: CGFloat = 28

    // MARK: - Actions

    /// Reveal the failing text in the editor.
    var onGoToError: (() -> Void)?
    /// Open the error sheet on this entry.
    var onDetails: (() -> Void)?
    /// Dismiss. The owner marks the entry read.
    var onClose: (() -> Void)?

    // MARK: - Views

    private let stripe = NSView()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let goToErrorButton = NSButton(title: "Go to Error", target: nil, action: nil)
    private let detailsButton = NSButton(title: "Details…", target: nil, action: nil)
    private let closeButton = NSButton()

    /// The failure on show, so the owner does not have to keep its own copy.
    private(set) var failureId: String?
    private(set) var tabId: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        // A tint of the error colour, not the colour itself: the bar is one
        // line of chrome the user reads past, not a block of red.
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor

        // The stripe carries the same meaning as the tint for anyone who
        // cannot see the tint — shape as well as colour.
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = NSColor.systemRed.cgColor
        stripe.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                 accessibilityDescription: "Error")
        iconView.contentTintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        // The message is the part that must give way when the bar is narrow;
        // the buttons keep their size.
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for button in [goToErrorButton, detailsButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        goToErrorButton.action = #selector(goToErrorTapped)
        goToErrorButton.toolTip = "Move the editor to the text this error points at."
        detailsButton.action = #selector(detailsTapped)
        detailsButton.toolTip = "Open the full message, with every other failure on this tab."

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityLabel("Dismiss this error")
        closeButton.toolTip = "Dismiss. The error stays on the tab's error button."

        let row = NSStackView(views: [iconView, messageLabel, goToErrorButton, detailsButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripe)
        addSubview(row)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),

            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            row.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("results.errorBanner")
    }

    // MARK: - Content

    /// Put a failure on the bar and announce it. The bar shows ONE failure —
    /// the newest — so a second call replaces the first rather than stacking.
    func show(_ failure: QueryFailure) {
        failureId = failure.id
        tabId = failure.tabId

        let message = DisplayEscape.escaped(failure.message)
        messageLabel.stringValue = message
        // Truncated to one line on screen; the whole of it is a hover away, and
        // "Details…" has it in full besides.
        toolTip = message
        messageLabel.toolTip = message

        let label = "Query error: \(message)"
        setAccessibilityLabel(label)
        isHidden = false

        // Nothing moves the focus here, so a screen reader would never reach
        // the bar on its own — the message has to be announced.
        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: label,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Take the bar off screen. It keeps no failure afterwards, so a stale
    /// "Details…" cannot open the wrong entry.
    func hide() {
        isHidden = true
        failureId = nil
        tabId = nil
        messageLabel.stringValue = ""
        toolTip = nil
    }

    // MARK: - Targets

    @objc private func goToErrorTapped() { onGoToError?() }
    @objc private func detailsTapped() { onDetails?() }
    @objc private func closeTapped() { onClose?() }

    // Test seams.
    var messageText: String { messageLabel.stringValue }
    var accessibilityLabelForTesting: String { accessibilityLabel() ?? "" }
    var goToErrorButtonForTesting: NSButton { goToErrorButton }
    var detailsButtonForTesting: NSButton { detailsButton }
    var closeButtonForTesting: NSButton { closeButton }
}
