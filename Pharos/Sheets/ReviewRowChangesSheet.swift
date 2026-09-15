import AppKit

/// The last thing between a pending cell edit and the user's database: the
/// exact `UPDATE` statements, one per row, with the key they are matched on
/// named underneath.
///
/// This is NOT a confirmation dialog, and it is shown whether or not
/// "Confirm destructive queries" is on. It is the only place the SQL is
/// visible at all — the user never typed it — so hiding it behind a setting
/// would mean applying statements nobody had ever seen.
///
/// The text comes from `RowUpdateSQLBuilder`, which renders values inline FOR
/// READING. The values that actually travel are in the `RowUpdateRequest` and
/// are bound by the core; see that file's header.
final class ReviewRowChangesSheet: NSViewController {

    private let request: RowUpdateRequest
    private let onApply: () -> Void

    // Stored so the key view loop and the tests can reach them.
    private let textView = NSTextView()
    private let cancelButton = NSButton()
    private let applyButton = NSButton()

    init(request: RowUpdateRequest, onApply: @escaping () -> Void) {
        self.request = request
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 420))
        self.view = container

        let titleLabel = NSTextField(labelWithString: RowUpdateSQLBuilder.title(for: request))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("sheet.reviewRowChanges.title")

        // Monospaced and non-editable: this is a transcript of what will run,
        // not a field. Writing Tools is off for the same reason — an
        // intelligence feature that rewrote a SQL statement in place would
        // change what the user is approving.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.writingToolsBehavior = .none
        textView.string = RowUpdateSQLBuilder.text(for: request)
        textView.setAccessibilityLabel(String(localized: "Statements to apply"))
        textView.setAccessibilityIdentifier("sheet.reviewRowChanges.statements")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let footnote = NSTextField(labelWithString: RowUpdateSQLBuilder.footnote(for: request))
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        footnote.maximumNumberOfLines = 2
        footnote.setAccessibilityIdentifier("sheet.reviewRowChanges.footnote")

        cancelButton.title = String(localized: "Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSheet)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("sheet.reviewRowChanges.cancel")

        applyButton.title = String(localized: "Apply")
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applySheet)
        applyButton.keyEquivalent = "\r"
        // It writes to the user's database and there is no undo, so it carries
        // the destructive treatment even though it is the default button.
        applyButton.hasDestructiveAction = true
        applyButton.setAccessibilityIdentifier("sheet.reviewRowChanges.default")

        let buttonRow = NSStackView(views: [Self.spacer(), cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, scrollView, footnote, buttonRow])
        stack.orientation = .vertical
        // `.leading` plus a width pin on each row: NSStackView silently rejects
        // a `.width` alignment (tasks/lessons.md), so the rows are pinned to
        // the stack's own width instead.
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            footnote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.initialFirstResponder = applyButton
    }

    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }

    // MARK: - Actions

    @objc private func cancelSheet() {
        dismiss(nil)
    }

    @objc private func applySheet() {
        // The sheet closes first and the caller runs afterwards: AppKit ends a
        // sheet asynchronously, and anything the apply path presents (a failure
        // alert) must not race this teardown.
        dismiss(nil)
        onApply()
    }

    // Test seams.
    var statementTextForTesting: String { textView.string }
    var titleForTesting: String { RowUpdateSQLBuilder.title(for: request) }
    var footnoteForTesting: String { RowUpdateSQLBuilder.footnote(for: request) }
    var applyButtonForTesting: NSButton { applyButton }
    var cancelButtonForTesting: NSButton { cancelButton }
}
