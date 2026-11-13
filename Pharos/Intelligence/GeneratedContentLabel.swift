import AppKit

/// The one-line header that sits above anything a model wrote.
///
/// Three jobs. It says the text below was generated, which the user is owed
/// before they act on it; it says by WHICH model, and so whether the prompt
/// left this Mac; and it takes a thumbs up or thumbs down so the feature can
/// be told apart from the ones that answer well.
///
/// A feature builds one per generated block, sets `promptHash` before showing
/// it, and reads `onFeedback` if it wants to react. The rating is written to
/// `ModelFeedbackStore` either way.
///
/// The model named is the one chosen when `promptHash` was last set — when
/// the request was made. A label that re-read the setting whenever it was
/// drawn would rename an answer already on screen after the user switched
/// models.
final class GeneratedContentLabel: NSView {

    /// Which feature this label belongs to — `"explain-error"`,
    /// `"suggest-name"` and so on. Recorded with the rating.
    let feature: String

    /// The digest of the prompt that produced the text below, from
    /// `ModelFeedbackStore.promptHash(_:)`. Set it before the label is shown;
    /// a rating given without one still records the feature.
    var promptHash: String? {
        didSet { source = IntelligenceSource.current() }
    }

    /// Which model the text below came from. Set with `promptHash`.
    private(set) var source = IntelligenceSource.current() {
        didSet { if source != oldValue { showSource() } }
    }

    /// Called after a thumb is pressed, with `1` or `-1`. The rating is
    /// already recorded by then.
    var onFeedback: ((Int) -> Void)?

    /// The rating already given, so a second press on the same thumb does
    /// nothing and the user cannot stack duplicate rows by leaning on it.
    private(set) var recordedRating: Int?

    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let thumbsUp = NSButton()
    private let thumbsDown = NSButton()

    // MARK: - Init

    init(feature: String) {
        self.feature = feature
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)

        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        // The caption yields before the buttons do: a narrow pane should
        // shorten the sentence, not clip the controls.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(thumbsUp, symbol: "hand.thumbsup",
                  label: String(localized: "Helpful"), action: #selector(helpfulPressed))
        configure(thumbsDown, symbol: "hand.thumbsdown",
                  label: String(localized: "Not helpful"), action: #selector(notHelpfulPressed))

        let stack = NSStackView(views: [icon, caption, NSView(), thumbsUp, thumbsDown])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])

        // A plain NSView is not an accessibility element until it says so;
        // without this the group, its role and its identifier never reach the
        // tree (the children still do).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("intelligence.label")
        showSource()
    }

    /// Write the model's name into the caption, the badge and the
    /// accessibility label.
    private func showSource() {
        let text = source.generatedBy
        caption.stringValue = text
        // A long model name or host is cut in a narrow pane; the tooltip
        // still carries all of it.
        caption.toolTip = text
        icon.image = NSImage(systemSymbolName: source.badgeSymbol, accessibilityDescription: text)
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: text)
        setAccessibilityLabel(text)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    // MARK: - Rating

    @objc private func helpfulPressed() { rate(1) }
    @objc private func notHelpfulPressed() { rate(-1) }

    /// Records a rating and tints the thumb that carries it.
    ///
    /// Pressing the same thumb again does nothing. Pressing the OTHER one is a
    /// change of mind and is recorded: the store keeps both rows, so the later
    /// one is the answer.
    private func rate(_ rating: Int) {
        guard recordedRating != rating else { return }
        recordedRating = rating
        ModelFeedbackStore.record(feature: feature, promptHash: promptHash, rating: rating)
        thumbsUp.contentTintColor = rating == 1 ? .controlAccentColor : .secondaryLabelColor
        thumbsDown.contentTintColor = rating == -1 ? .controlAccentColor : .secondaryLabelColor
        onFeedback?(rating)
    }

    // MARK: - Test access

    /// The two thumbs, in order. Only a test reads these; the feature talks to
    /// the label through `onFeedback`.
    var feedbackButtons: [NSButton] { [thumbsUp, thumbsDown] }
}
