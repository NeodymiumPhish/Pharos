import AppKit
import FoundationModels

/// What the on-device model says about a query plan.
@Generable
struct PlanSummary {

    @Guide(description: "two or three sentences")
    var summary: String

    @Guide(description: "the node type and relation of the slowest step")
    var slowestNode: String

    @Guide(description: "one concrete suggestion, or nil")
    var suggestion: String?
}

/// Asks the on-device model to read a query plan.
///
/// The prompt is built by `PlanSummaryPrompt` and passed in rather than built
/// here, so the caller can hash exactly the text the model was given for
/// `GeneratedContentLabel.promptHash` without building it twice.
@MainActor
final class PlanSummarizer {

    func summarize(prompt: String) async throws -> PlanSummary {
        try IntelligenceGuard.requireAvailable()
        let session = LanguageModelSession(
            instructions: IntelligenceInstructions.sqlSafety + "\n" + PlanSummaryPrompt.instructions)
        return try await session.respond(to: prompt, generating: PlanSummary.self).content
    }
}

/// The block that sits between the plan view's header row and its outline.
///
/// Four states, one view: hidden (the feature is off or there is no plan),
/// working (a spinner and a line of progress text), answered (the label, the
/// paragraph, the slowest step and — when there is one — a suggestion), and
/// failed (a short sentence and Retry).
///
/// The generated text never replaces the outline. The numbers stay where they
/// were; this is a reading of them, and it is marked as one.
final class PlanSummaryView: NSView {

    /// Called when the user presses Retry.
    var onRetry: (() -> Void)?

    /// Set before the answer is shown, so a thumb records which prompt it
    /// judged. Forwarded to the label.
    var promptHash: String? {
        get { label.promptHash }
        set { label.promptHash = newValue }
    }

    private let label = GeneratedContentLabel(feature: "plan-summary")
    private let spinner = NSProgressIndicator()
    private let progressText = NSTextField(labelWithString: "")
    private let summaryText = NSTextField(wrappingLabelWithString: "")
    private let slowestText = NSTextField(labelWithString: "")
    private let suggestionText = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()

    private let progressRow = NSStackView()
    private let retryRow = NSStackView()
    private let contentStack = NSStackView()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        build()
        setState(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        progressText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressText.textColor = .secondaryLabelColor

        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 6
        progressRow.setViews([spinner, progressText, NSView()], in: .leading)

        summaryText.font = .systemFont(ofSize: NSFont.systemFontSize)
        summaryText.setAccessibilityIdentifier("plan.summary.text")

        slowestText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        slowestText.textColor = .secondaryLabelColor
        slowestText.lineBreakMode = .byTruncatingTail
        slowestText.setAccessibilityIdentifier("plan.summary.slowest")

        suggestionText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        suggestionText.textColor = .secondaryLabelColor
        suggestionText.setAccessibilityIdentifier("plan.summary.suggestion")

        retryButton.title = String(localized: "Retry")
        retryButton.bezelStyle = .accessoryBarAction
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.setAccessibilityIdentifier("plan.summary.retry")

        retryRow.orientation = .horizontal
        retryRow.spacing = 6
        retryRow.setViews([retryButton, NSView()], in: .leading)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setViews([label, progressRow, summaryText, slowestText, suggestionText, retryRow], in: .leading)
        contentStack.spanArrangedSubviewsFullWidth()

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Plan summary"))
        setAccessibilityIdentifier("plan.summary")
    }

    // MARK: - States

    enum State {
        case idle
        case working
        case answered(PlanSummary)
        case failed(String)
    }

    /// Show one of the four states. Hiding an arranged subview of an
    /// `NSStackView` takes it out of the layout, so the block is exactly as
    /// tall as the state it is in.
    func setState(_ state: State) {
        switch state {
        case .idle:
            isHidden = true
            spinner.stopAnimation(nil)

        case .working:
            isHidden = false
            label.isHidden = true
            progressRow.isHidden = false
            progressText.stringValue = String(localized: "Summarising the plan…")
            spinner.startAnimation(nil)
            summaryText.isHidden = true
            slowestText.isHidden = true
            suggestionText.isHidden = true
            retryRow.isHidden = true

        case .answered(let summary):
            isHidden = false
            spinner.stopAnimation(nil)
            progressRow.isHidden = true
            label.isHidden = false
            summaryText.isHidden = false
            summaryText.stringValue = summary.summary
            slowestText.isHidden = summary.slowestNode.isEmpty
            slowestText.stringValue = String(localized: "Slowest step: \(summary.slowestNode)")
            let suggestion = summary.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            suggestionText.isHidden = suggestion.isEmpty
            suggestionText.stringValue = String(localized: "Suggestion: \(suggestion)")
            retryRow.isHidden = true

        case .failed(let message):
            isHidden = false
            spinner.stopAnimation(nil)
            progressRow.isHidden = true
            label.isHidden = true
            summaryText.isHidden = false
            summaryText.stringValue = message
            slowestText.isHidden = true
            suggestionText.isHidden = true
            retryRow.isHidden = false
        }
    }

    @objc private func retryPressed() { onRetry?() }
}
