import AppKit
import FoundationModels

/// "Describe the query…" — the popover behind the editor toolbar's
/// Apple Intelligence button.
///
/// The analyst writes a sentence; the model answers with one statement and a
/// note about what it assumed. Nothing is run. The draft reaches the editor
/// only when Insert is pressed, and a draft that is not a plain `SELECT` asks
/// once more before it goes in.
@MainActor
final class DescribeQueryPopoverVC: NSViewController {

    /// The SQL to insert, already cleaned and already confirmed.
    var onInsert: ((String) -> Void)?

    /// Asks the host to close the popover.
    var onClose: (() -> Void)?

    // MARK: - Inputs

    private let snapshot: SchemaSnapshot
    private let defaultSchema: String?

    // MARK: - Views

    private let generatedLabel = GeneratedContentLabel(feature: "draft-sql")
    private let promptField = NSTextField()
    private let spinner = NSProgressIndicator()
    private let progressRow = NSStackView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let draftButton = NSButton()
    private let insertButton = NSButton()
    private let retryButton = NSButton()
    private let cancelButton = NSButton()
    private let buttonRow = NSStackView()

    // MARK: - State

    /// The review of the draft on screen, or nil while there is none.
    private(set) var review: SQLDraftPolicy.Review?

    private var draftTask: Task<Void, Never>?

    /// Stops a session that will not finish.
    ///
    /// A model that loops on its own tools answers nothing and shows the
    /// analyst a spinner for as long as they are willing to watch it. The
    /// instructions are written to prevent that (see `SQLDrafter`), and this
    /// is the floor under them: a minute, then the retry.
    private var timeoutTask: Task<Void, Never>?
    private let draftTimeout: Duration = .seconds(60)

    /// The words the current draft was asked for, so Retry asks the same
    /// question of a NEW session rather than of the one that just answered.
    private var lastDescription = ""

    // MARK: - Init

    init(snapshot: SchemaSnapshot, defaultSchema: String?) {
        self.snapshot = snapshot
        self.defaultSchema = defaultSchema
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("intelligence.describeQuery")

        generatedLabel.isHidden = true

        let prompt = NSTextField(labelWithString: String(localized: "What should the query return?"))
        prompt.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        // Multi-line: a description is a sentence, sometimes two. The field
        // wraps rather than scrolling sideways, and ⌘↩ is what sends it, so
        // the field keeps Return for the analyst.
        promptField.placeholderString = String(localized: "Orders per region this year")
        promptField.isBezeled = true
        promptField.bezelStyle = .squareBezel
        promptField.usesSingleLineMode = false
        promptField.cell?.wraps = true
        promptField.cell?.isScrollable = false
        promptField.maximumNumberOfLines = 4
        promptField.lineBreakMode = .byWordWrapping
        promptField.delegate = self
        promptField.setAccessibilityIdentifier("intelligence.describeQuery.field")
        promptField.setAccessibilityLabel(String(localized: "What should the query return?"))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let progressLabel = NSTextField(labelWithString: String(localized: "Drafting\u{2026}"))
        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressLabel.textColor = .secondaryLabelColor

        progressRow.setViews([spinner, progressLabel], in: .leading)
        progressRow.orientation = .horizontal
        progressRow.spacing = 6
        progressRow.isHidden = true

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true
        noteLabel.setAccessibilityIdentifier("intelligence.describeQuery.note")

        configure(draftButton, title: String(localized: "Draft"), action: #selector(draftPressed))
        draftButton.keyEquivalent = "\r"
        draftButton.keyEquivalentModifierMask = [.command]
        draftButton.toolTip = String(localized: "Draft the query (\u{2318}\u{21A9})")
        draftButton.setAccessibilityIdentifier("intelligence.describeQuery.draft")

        configure(insertButton, title: String(localized: "Insert"), action: #selector(insertPressed))
        insertButton.isHidden = true
        insertButton.setAccessibilityIdentifier("intelligence.describeQuery.insert")

        configure(retryButton, title: String(localized: "Retry"), action: #selector(retryPressed))
        retryButton.isHidden = true
        retryButton.setAccessibilityIdentifier("intelligence.describeQuery.retry")

        configure(cancelButton, title: String(localized: "Cancel"), action: #selector(cancelPressed))
        cancelButton.keyEquivalent = "\u{1b}"

        buttonRow.setViews([NSView(), cancelButton, retryButton, insertButton, draftButton], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            generatedLabel, prompt, promptField, progressRow, noteLabel, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(equalToConstant: 360),
            promptField.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        // The rows that must span the popover. `NSStackView.alignment` has no
        // `.fill`, and setting `.width` is silently rejected — pin instead.
        for row in [generatedLabel, promptField, noteLabel, buttonRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view = container
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = action
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(promptField)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // A popover that is dismissed mid-generation must not leave the
        // session running and then touch views that are going away.
        cancelDraft()
    }

    // MARK: - Actions

    @objc private func draftPressed() { startDraft() }

    /// Retry asks the SAME question of a NEW `SQLDrafter`, so the model does
    /// not treat its previous answer as something to keep.
    @objc private func retryPressed() {
        promptField.stringValue = lastDescription.isEmpty ? promptField.stringValue : lastDescription
        startDraft()
    }

    @objc private func cancelPressed() {
        cancelDraft()
        onClose?()
    }

    @objc private func insertPressed() {
        guard let review, !review.isEmpty else { return }

        guard let warning = review.warning else {
            commit(review.sql)
            return
        }

        // Not a plain SELECT. Pharos still will not run it — but a statement
        // that writes has no business arriving in the editor unannounced.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Insert this draft?")
        alert.informativeText = warning
        alert.addButton(withTitle: String(localized: "Insert Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true

        guard let window = view.window else {
            if alert.runModal() == .alertFirstButtonReturn { commit(review.sql) }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let review = self.review else { return }
            self.commit(review.sql)
        }
    }

    private func commit(_ sql: String) {
        onInsert?(sql)
        onClose?()
    }

    // MARK: - Drafting

    private func startDraft() {
        let description = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            view.window?.makeFirstResponder(promptField)
            NSSound.beep()
            return
        }

        cancelDraft()
        lastDescription = description
        review = nil
        showDrafting()

        // A fresh drafter per attempt: one session per interaction, as every
        // Phase 8 feature does it.
        let drafter = SQLDrafter(snapshot: snapshot, defaultSchema: defaultSchema)
        draftTask = Task { [weak self] in
            do {
                let draft = try await drafter.draft(description)
                guard !Task.isCancelled else { return }
                self?.timeoutTask?.cancel()
                self?.show(draft: draft, for: description)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.timeoutTask?.cancel()
                self?.show(error: error)
            }
        }

        timeoutTask = Task { [weak self] in
            guard let timeout = self?.draftTimeout else { return }
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.draftTask?.cancel()
            self.draftTask = nil
            Log.intelligence.error("draft-sql: timed out")
            self.spinner.stopAnimation(nil)
            self.progressRow.isHidden = true
            self.draftButton.isEnabled = true
            self.promptField.isEnabled = true
            self.insertButton.isHidden = true
            self.draftButton.isHidden = true
            self.retryButton.isHidden = false
            self.show(message: String(localized: "The model did not finish in time. Try again."),
                      isFailure: true)
        }
    }

    private func cancelDraft() {
        draftTask?.cancel()
        draftTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func showDrafting() {
        spinner.startAnimation(nil)
        progressRow.isHidden = false
        generatedLabel.isHidden = true
        noteLabel.isHidden = true
        insertButton.isHidden = true
        retryButton.isHidden = true
        draftButton.isEnabled = false
        promptField.isEnabled = false
    }

    private func show(draft: SQLDraft, for description: String) {
        spinner.stopAnimation(nil)
        progressRow.isHidden = true
        draftButton.isEnabled = true
        promptField.isEnabled = true

        let reviewed = SQLDraftPolicy.review(draft.sql)
        review = reviewed

        guard !reviewed.isEmpty else {
            // An answer with no statement in it is a failure with a nicer
            // shape: offer the retry, not an Insert that inserts nothing.
            show(message: String(localized: "The model did not write a statement. Try again."),
                 isFailure: true)
            return
        }

        generatedLabel.promptHash = ModelFeedbackStore.promptHash(description)
        generatedLabel.isHidden = false

        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = note.isEmpty ? String(localized: "No assumptions given.") : note
        if let warning = reviewed.warning {
            show(message: "\(warning)\n\(sentence)", isFailure: true)
        } else {
            show(message: sentence, isFailure: false)
        }

        // Insert gets no Return key equivalent: the description field keeps
        // Return for the analyst, and an insert is the one step here that
        // changes the document.
        insertButton.isHidden = false
        draftButton.isHidden = true
        retryButton.isHidden = false
    }

    private func show(error: Error) {
        spinner.stopAnimation(nil)
        progressRow.isHidden = true
        draftButton.isEnabled = true
        promptField.isEnabled = true
        generatedLabel.isHidden = true
        insertButton.isHidden = true
        draftButton.isHidden = true
        retryButton.isHidden = false
        review = nil
        show(message: Self.message(for: error), isFailure: true)
    }

    private func show(message: String, isFailure: Bool) {
        noteLabel.stringValue = message
        noteLabel.textColor = isFailure ? .systemOrange : .secondaryLabelColor
        noteLabel.isHidden = false
    }

    /// One short sentence per failure the model can report.
    static func message(for error: Error) -> String {
        if let intelligence = error as? IntelligenceError {
            return intelligence.localizedDescription
        }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return String(localized: "The model could not draft a query. Try again.")
        }
        switch generation {
        case .guardrailViolation:
            return String(localized: "The model would not answer that. Try describing the query another way.")
        case .exceededContextWindowSize:
            return String(localized: "That was too much for one request. Choose a schema first, or describe a smaller query.")
        case .unsupportedLanguageOrLocale:
            return String(localized: "The model does not support this language yet.")
        default:
            return String(localized: "The model could not draft a query. Try again.")
        }
    }
}

// MARK: - NSTextFieldDelegate

extension DescribeQueryPopoverVC: NSTextFieldDelegate {

    /// A new description invalidates the draft on screen: Insert must never
    /// put in SQL that answers a question the analyst has since rewritten.
    func controlTextDidChange(_ obj: Notification) {
        guard review != nil else { return }
        review = nil
        generatedLabel.isHidden = true
        noteLabel.isHidden = true
        insertButton.isHidden = true
        retryButton.isHidden = true
        draftButton.isHidden = false
    }
}
