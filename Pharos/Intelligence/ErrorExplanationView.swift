import AppKit
import Combine

/// The "Explain this error" block: the generated-content label, then the cause,
/// where it is, and what to do about it.
///
/// It owns its own session through `ErrorExplainer`, so the sheet hands it a
/// failure and nothing else. It is entirely absent — not disabled, not empty —
/// when Apple Intelligence is unavailable or turned off, and it goes away by
/// itself if the user clears the setting while the sheet is open.
///
/// Height follows the text: every label wraps, nothing scrolls, and the sheet
/// grows by as much as the answer needs.
final class ErrorExplanationView: NSView, QueryErrorExplaining {

    /// Recorded with a thumbs up or down, and the string the docs name.
    static let feature = "explain-error"

    // MARK: - Views

    private let label = GeneratedContentLabel(feature: ErrorExplanationView.feature)
    private let spinner = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: String(localized: "Explaining the error…"))
    private let causeLabel = NSTextField(wrappingLabelWithString: "")
    private let locationLabel = NSTextField(wrappingLabelWithString: "")
    private let fixesStack = NSStackView()
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: String(localized: "Retry"), target: nil, action: nil)
    private lazy var progressRow = NSStackView(views: [spinner, progressLabel])
    private lazy var failureRow = NSStackView(views: [failureLabel, retryButton])
    private lazy var root = NSStackView(views: [
        label, progressRow, causeLabel, locationLabel, fixesStack, failureRow,
    ])

    // MARK: - State

    private let explainer = ErrorExplainer()
    private var consumer: Task<Void, Never>?
    private var failure: QueryFailure?
    private var availability: AnyCancellable?

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        build()
        // The setting can be cleared in another window while this sheet is open.
        // Losing availability takes the block away with everything it holds.
        availability = ModelAvailability.shared.$isAvailable
            .removeDuplicates()
            .sink { [weak self] available in
                guard let self, !available else { return }
                self.explain(nil)
            }
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
        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressLabel.textColor = .secondaryLabelColor
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 6

        causeLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        causeLabel.setAccessibilityIdentifier("intelligence.explainError.cause")

        locationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.setAccessibilityIdentifier("intelligence.explainError.location")

        fixesStack.orientation = .vertical
        fixesStack.alignment = .leading
        fixesStack.spacing = 2
        fixesStack.setAccessibilityIdentifier("intelligence.explainError.fixes")

        failureLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        failureLabel.textColor = .secondaryLabelColor
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        failureRow.orientation = .horizontal
        failureRow.alignment = .centerY
        failureRow.spacing = 8

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A stack view silently rejects `.fill` alignment (and `.width`),
            // so each row that must span the block pins its own width to the
            // stack's — see NSStackView+SpanFullWidth.swift for the same trick.
            label.widthAnchor.constraint(equalTo: root.widthAnchor),
            failureRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            causeLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            locationLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            fixesStack.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("intelligence.explainError")
        clear()
        isHidden = true
    }

    /// A wrapping label needs to be told how wide it may be, and the answer only
    /// exists once the sheet has laid out.
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        for field in [causeLabel, locationLabel, failureLabel] {
            field.preferredMaxLayoutWidth = width
        }
        for field in fixesStack.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
            field.preferredMaxLayoutWidth = width
        }
    }

    // MARK: - QueryErrorExplaining

    var explanationView: NSView { self }

    /// Explain `failure`, or take the block off screen when it is nil.
    ///
    /// Calling it again replaces the answer on screen and ends the run behind
    /// the old one, so stepping through the sheet's entries never leaves a
    /// previous explanation half-written under a new error.
    func explain(_ failure: QueryFailure?) {
        consumer?.cancel()
        consumer = nil
        explainer.cancel()
        self.failure = failure
        clear()

        guard let failure, failure.kind == .error, ModelAvailability.shared.isAvailable else {
            isHidden = true
            return
        }
        isHidden = false
        start(failure)
    }

    private func start(_ failure: QueryFailure) {
        let known = ErrorExplanationPrompt.KnownObjects.from(
            cache: MetadataCache.shared, sql: failure.sql)
        let run: ErrorExplanationRun
        do {
            run = try explainer.explain(failure: failure, knownObjects: known)
        } catch {
            show(error)
            return
        }

        label.promptHash = run.promptHash
        label.isHidden = false
        setProgress(true)

        consumer = Task { @MainActor [weak self] in
            do {
                for try await partial in run.updates {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(partial)
                }
                self?.setProgress(false)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.show(error)
            }
        }
    }

    @objc private func retryPressed() { retry() }

    /// Start again with a fresh session. The Retry button, and nothing else,
    /// calls this.
    func retry() {
        guard let failure else { return }
        explain(failure)
    }

    // MARK: - Content

    private func apply(_ partial: ErrorExplanation.PartiallyGenerated) {
        set(causeLabel, Self.unwrap(partial.cause))
        set(locationLabel, Self.unwrap(partial.location))
        setFixes(Self.unwrapList(partial.fixes))
        needsLayout = true
    }

    private func set(_ field: NSTextField, _ text: String?) {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = value
        field.isHidden = value.isEmpty
    }

    private func setFixes(_ fixes: [String]) {
        let wanted = fixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for view in fixesStack.arrangedSubviews { view.removeFromSuperview() }
        for fix in wanted {
            let bullet = NSTextField(wrappingLabelWithString: "•  \(fix)")
            bullet.font = .systemFont(ofSize: NSFont.systemFontSize)
            bullet.preferredMaxLayoutWidth = bounds.width
            fixesStack.addArrangedSubview(bullet)
            bullet.widthAnchor.constraint(equalTo: fixesStack.widthAnchor).isActive = true
        }
        fixesStack.isHidden = wanted.isEmpty
    }

    private func setProgress(_ running: Bool) {
        progressRow.isHidden = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func show(_ error: Error) {
        setProgress(false)
        failureLabel.stringValue = ErrorExplainer.userMessage(for: error)
        failureRow.isHidden = false
        needsLayout = true
    }

    /// Back to an empty block: no answer, no progress, no failure.
    private func clear() {
        label.isHidden = true
        label.promptHash = nil
        setProgress(false)
        set(causeLabel, nil)
        set(locationLabel, nil)
        setFixes([])
        failureLabel.stringValue = ""
        failureRow.isHidden = true
    }

    // MARK: - Partial unwrapping

    // `PartiallyGenerated` makes every property optional, and a property that
    // was ALREADY optional can land as either `String?` or `String??` depending
    // on the macro's expansion. One overload per shape, so the call site reads
    // the same whichever the compiler picks.
    private static func unwrap(_ value: String?) -> String? { value }
    private static func unwrap(_ value: String??) -> String? { value ?? nil }
    private static func unwrapList(_ value: [String]?) -> [String] { value ?? [] }
    private static func unwrapList(_ value: [String]??) -> [String] { (value ?? nil) ?? [] }

    // MARK: - Test access

    /// What the block says, for a test that drives it without a model.
    var causeText: String { causeLabel.stringValue }
    var locationText: String { locationLabel.stringValue }
    var fixTexts: [String] { fixesStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var failureText: String { failureLabel.stringValue }
    var isShowingProgress: Bool { !progressRow.isHidden }
    var generatedLabel: GeneratedContentLabel { label }
    var retryButtonForTesting: NSButton { retryButton }
}
