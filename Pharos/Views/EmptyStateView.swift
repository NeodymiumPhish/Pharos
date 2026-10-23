import AppKit

/// The system-style empty state: a large symbol, a title, one line of text
/// and at most one action button, centred in its container. `showProgress`
/// is its waiting form: a spinning indicator and one line.
///
/// AppKit has no `NSContentUnavailableConfiguration` (that class is UIKit
/// only), so this view fills the role for the results grid and the three
/// sidebar lists. Configure it with `show(...)`; hide it with `isHidden`.
final class EmptyStateView: NSView {

    private let imageView = NSImageView()
    private let spinner = NSProgressIndicator()
    private var inProgress = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // The view's own label says what is happening.
        spinner.setAccessibilityElement(false)

        let stack = NSStackView(views: [spinner, imageView, titleLabel, messageLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: imageView)
        stack.setCustomSpacing(12, after: spinner)
        stack.setCustomSpacing(16, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 44),
            imageView.heightAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            trailingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// Shows the state. `actionTitle == nil` hides the button.
    func show(symbol: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        setProgress(false)
        imageView.isHidden = false
        titleLabel.isHidden = false
        messageLabel.textColor = .tertiaryLabelColor
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        self.action = action
        if let actionTitle, action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        setAccessibilityLabel(message.isEmpty ? title : "\(title). \(message)")
        isHidden = false
    }

    /// The waiting form: a spinning indicator and `text`, which says what is
    /// happening (HIG, Progress indicators). It spins while it is on screen.
    func showProgress(_ text: String) {
        imageView.isHidden = true
        titleLabel.isHidden = true
        actionButton.isHidden = true
        action = nil
        messageLabel.stringValue = text
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = false
        setAccessibilityLabel(text)
        isHidden = false
        setProgress(true)
    }

    private func setProgress(_ on: Bool) {
        inProgress = on
        spinner.isHidden = !on
        updateSpinner()
    }

    private func updateSpinner() {
        if inProgress && window != nil && !isHiddenOrHasHiddenAncestor {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinner()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateSpinner()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateSpinner()
    }

    @objc private func actionTapped() {
        action?()
    }

    // Test seams.
    var titleText: String { titleLabel.stringValue }
    var isShowingProgress: Bool { inProgress && !spinner.isHidden }
    var messageText: String { messageLabel.stringValue }
    var actionButtonForTesting: NSButton { actionButton }
}
