import AppKit

/// What the sheet reports back. The sheet holds no truth: the owner keeps the
/// tab's `QueryFailureLog`, changes it, and hands the sheet a new list.
protocol QueryErrorSheetDelegate: AnyObject {
    /// The sheet put this entry on screen. The owner marks it read.
    func errorSheet(_ sheet: QueryErrorSheet, didShow failureId: String, tabId: String)
    /// Take this one entry out of the log for good.
    func errorSheet(_ sheet: QueryErrorSheet, didRequestDismiss failureId: String, tabId: String)
    /// Empty the log.
    func errorSheetDidRequestDismissAll(_ sheet: QueryErrorSheet, tabId: String)
    /// Go to the faulty character in the editor.
    func errorSheet(_ sheet: QueryErrorSheet, didRequestGoToError failure: QueryFailure)
    /// Close the sheet and keep every entry.
    func errorSheetDidRequestClose(_ sheet: QueryErrorSheet)
}

/// Modal sheet for one query failure, with Previous/Next across the tab's log.
///
/// It replaces the old behaviour, where a failure wiped the results grid. The
/// grid now keeps the rows the user was reading.
final class QueryErrorSheet: NSViewController {

    weak var delegate: QueryErrorSheetDelegate?

    let tabId: String
    private(set) var entries: [QueryFailure]
    private(set) var index: Int

    // Internal so the standalone layout test can read and click them.
    let titleLabel = NSTextField(labelWithString: "")
    let symbolView = NSImageView()
    let subheaderLabel = NSTextField(labelWithString: "")
    let counterLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    let sqlTextView = NSTextView()
    let errorTextView = NSTextView()
    let goToErrorButton = NSButton(title: "Go to Error", target: nil, action: nil)
    let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    let dismissAllButton = NSButton(title: "Dismiss All", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let copyErrorButton = NSButton(title: "Copy Error", target: nil, action: nil)
    let copyQueryButton = NSButton(title: "Copy Query", target: nil, action: nil)

    private var current: QueryFailure? {
        guard index >= 0, index < entries.count else { return nil }
        return entries[index]
    }

    init(
        entries: [QueryFailure],
        index: Int,
        tabId: String,
        delegate: QueryErrorSheetDelegate?
    ) {
        self.entries = entries
        self.index = min(max(index, 0), max(entries.count - 1, 0))
        self.tabId = tabId
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Take a new entry list from the owner, after a dismissal or a new failure.
    func update(entries: [QueryFailure], index: Int) {
        // An empty list has nothing to show. Ask the owner to close rather than
        // leaving the last entry on screen, which would read as a live failure.
        guard !entries.isEmpty else {
            self.entries = []
            delegate?.errorSheetDidRequestClose(self)
            return
        }
        self.entries = entries
        self.index = min(max(index, 0), max(entries.count - 1, 0))
        guard isViewLoaded else { return }
        applyCurrent()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        view = container

        // Header: symbol, title, then the counter and the arrows on the right.
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        counterLabel.font = .systemFont(ofSize: 11)
        counterLabel.textColor = .secondaryLabelColor

        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        previousButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Error")?
            .withSymbolConfiguration(arrowConfig)
        previousButton.bezelStyle = .rounded
        previousButton.target = self
        previousButton.action = #selector(showPrevious)
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Error")?
            .withSymbolConfiguration(arrowConfig)
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(showNext)

        let headerRight = NSStackView(views: [counterLabel, previousButton, nextButton])
        headerRight.orientation = .horizontal
        headerRight.spacing = 4

        let header = NSStackView(views: [symbolView, titleLabel, Self.spacer(), headerRight])
        header.orientation = .horizontal
        header.spacing = 8

        subheaderLabel.font = .systemFont(ofSize: 11)
        subheaderLabel.textColor = .secondaryLabelColor

        // SQL, read-only but selectable, with editor colouring.
        let sqlScroll = NSScrollView()
        sqlScroll.hasVerticalScroller = true
        sqlScroll.borderType = .bezelBorder
        sqlScroll.drawsBackground = true
        configure(textView: sqlTextView, monospaced: true)
        sqlScroll.documentView = sqlTextView
        sqlScroll.translatesAutoresizingMaskIntoConstraints = false
        sqlScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // The error message, selectable so the user can copy part of it.
        let errorScroll = NSScrollView()
        errorScroll.hasVerticalScroller = true
        errorScroll.borderType = .bezelBorder
        errorScroll.drawsBackground = true
        configure(textView: errorTextView, monospaced: false)
        errorScroll.documentView = errorTextView
        errorScroll.translatesAutoresizingMaskIntoConstraints = false
        errorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        for (button, action) in [
            (goToErrorButton, #selector(goToError)),
            (dismissButton, #selector(dismissCurrent)),
            (dismissAllButton, #selector(dismissAll)),
            (doneButton, #selector(requestClose)),
            (copyErrorButton, #selector(copyError)),
            (copyQueryButton, #selector(copyQuery)),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        doneButton.keyEquivalent = "\u{1b}"   // Escape

        let buttonRow = NSStackView(views: [
            copyErrorButton, copyQueryButton, goToErrorButton,
            Self.spacer(),
            dismissButton, dismissAllButton, doneButton,
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let root = NSStackView(views: [header, subheaderLabel, sqlScroll, errorScroll, buttonRow])
        root.orientation = .vertical
        // `.fill` does not exist on NSStackView.alignment; `.width` is what
        // stretches subviews across a vertical stack.
        root.alignment = .width
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        applyCurrent()
    }

    /// An empty view that takes the slack in a horizontal row, so the group after
    /// it sits at the trailing edge. A plain NSView would not give way, because
    /// its hugging priority matches the buttons'.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func configure(textView: NSTextView, monospaced: Bool) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
    }

    // MARK: - Showing an entry

    private func applyCurrent() {
        guard let failure = current else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        symbolView.image = NSImage(systemSymbolName: failure.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        symbolView.contentTintColor = failure.kind == .error ? .systemRed : .systemOrange
        titleLabel.stringValue = failure.title
        subheaderLabel.stringValue = failure.subheader

        errorTextView.string = failure.message
        errorTextView.textColor = .systemRed

        // Computed once here, not re-parsed by every reader: `location` re-runs
        // two regular expressions on each read.
        let highlight = failure.location?.range(in: failure.sql)
        applySQL(failure, highlight: highlight)

        let many = entries.count > 1
        counterLabel.isHidden = !many
        previousButton.isHidden = !many
        nextButton.isHidden = !many
        counterLabel.stringValue = QueryFailureLog.counterText(index: index, count: entries.count)
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < entries.count - 1
        goToErrorButton.isEnabled = highlight != nil

        delegate?.errorSheet(self, didShow: failure.id, tabId: tabId)
    }

    private func applySQL(_ failure: QueryFailure, highlight: NSRange?) {
        let colored = SQLSyntaxHighlighter.attributedString(
            for: failure.sql,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            baseColor: .textColor
        )
        let text = NSMutableAttributedString(attributedString: colored)
        if let highlight {
            text.addAttributes([
                .backgroundColor: NSColor.systemRed.withAlphaComponent(0.22),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemRed,
            ], range: highlight)
        }
        sqlTextView.textStorage?.setAttributedString(text)
        if let highlight {
            sqlTextView.scrollRangeToVisible(highlight)
        }
    }

    // MARK: - Actions

    @objc private func showPrevious() {
        guard index > 0 else { return }
        index -= 1
        applyCurrent()
    }

    @objc private func showNext() {
        guard index < entries.count - 1 else { return }
        index += 1
        applyCurrent()
    }

    @objc private func copyError() {
        guard let failure = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.message, forType: .string)
    }

    @objc private func copyQuery() {
        guard let failure = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.sql, forType: .string)
    }

    @objc private func goToError() {
        guard let failure = current else { return }
        delegate?.errorSheet(self, didRequestGoToError: failure)
    }

    @objc private func dismissCurrent() {
        guard let failure = current else { return }
        delegate?.errorSheet(self, didRequestDismiss: failure.id, tabId: tabId)
    }

    @objc private func dismissAll() {
        delegate?.errorSheetDidRequestDismissAll(self, tabId: tabId)
    }

    @objc private func requestClose() {
        delegate?.errorSheetDidRequestClose(self)
    }
}
