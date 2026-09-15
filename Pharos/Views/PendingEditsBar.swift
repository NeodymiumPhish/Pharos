import AppKit

/// One line across the top of the results area saying how many cell edits are
/// waiting, and offering the only two things that can be done with them.
///
/// Modelled on `QueryErrorBanner`: zero height and hidden when there is
/// nothing to say, `PendingEditsBar.height` when there is, with the owner
/// driving the height constraint so both sides agree on the one number.
///
/// It is deliberately a BAR and not a badge. A pending edit is a change the
/// user has not yet made to their database, and the app must not be able to
/// hold one quietly — the line stays on screen, on this result tab, until the
/// changes are applied or discarded.
final class PendingEditsBar: NSView {

    /// Height when shown.
    static let height: CGFloat = 28

    // MARK: - Actions

    /// Open the review sheet.
    var onReview: (() -> Void)?
    /// Throw the pending set away. The owner asks first.
    var onDiscard: (() -> Void)?

    // MARK: - Views

    private let stripe = NSView()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let reviewButton = NSButton(title: String(localized: "Review Changes…"), target: nil, action: nil)
    private let discardButton = NSButton(title: String(localized: "Discard"), target: nil, action: nil)

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
        // A tint of the accent, not the accent itself: the bar is a line of
        // chrome above the grid, not a block of colour.
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        // The stripe says the same thing as the tint for anyone who cannot see
        // the tint — shape as well as colour, the rule the grid's own pending
        // cells follow too.
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        stripe.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "pencil.line",
                                 accessibilityDescription: String(localized: "Pending changes"))
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        // The message gives way when the bar is narrow; the buttons do not.
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for button in [reviewButton, discardButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        reviewButton.action = #selector(reviewTapped)
        reviewButton.toolTip = String(localized: "Show the exact UPDATE statements before anything is written.")
        reviewButton.setAccessibilityIdentifier("results.pendingEdits.review")
        discardButton.action = #selector(discardTapped)
        discardButton.toolTip = String(localized: "Throw the pending changes away and reload the rows.")
        discardButton.setAccessibilityIdentifier("results.pendingEdits.discard")

        let row = NSStackView(views: [iconView, messageLabel, reviewButton, discardButton])
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

        // A plain NSView is an IGNORED accessibility element: without this the
        // role, the label and the identifier below change nothing in the tree
        // and the two buttons are hoisted to the parent.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("results.pendingEdits")

        isHidden = true
    }

    // MARK: - Content

    /// The text the bar shows for a given count and table.
    ///
    /// Pulled out as a static so the phrasing is asserted without a view:
    /// "1 change in public.users", "3 changes in public.users".
    static func message(changeCount: Int, tableDisplay: String) -> String {
        let changes = CountedNounText.phrase(changeCount, "change")
        guard !tableDisplay.isEmpty else { return changes }
        return String(localized: "\(changes) in \(DisplayEscape.escaped(tableDisplay))")
    }

    /// Put a count on the bar. A count of zero hides it instead — the caller
    /// never has to remember which of the two calls to make.
    func show(changeCount: Int, tableDisplay: String) {
        guard changeCount > 0 else { hide(); return }
        let text = Self.message(changeCount: changeCount, tableDisplay: tableDisplay)
        messageLabel.stringValue = text
        toolTip = text
        setAccessibilityLabel(text)
        isHidden = false
    }

    func hide() {
        isHidden = true
        messageLabel.stringValue = ""
        toolTip = nil
    }

    // MARK: - Targets

    @objc private func reviewTapped() { onReview?() }
    @objc private func discardTapped() { onDiscard?() }

    // Test seams.
    var messageText: String { messageLabel.stringValue }
    var accessibilityLabelForTesting: String { accessibilityLabel() ?? "" }
    var reviewButtonForTesting: NSButton { reviewButton }
    var discardButtonForTesting: NSButton { discardButton }
}
