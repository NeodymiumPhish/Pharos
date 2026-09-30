import AppKit
import Combine

/// Delegate for popover row actions. `MainToolbarController` conforms and
/// forwards each request to the `ContentViewController`, which stays the
/// single owner of cancellation logic.
/// `@MainActor`: a UI delegate, called from the popover's own view code, and
/// its one conformer (`MainToolbarController`) is main-actor isolated. Without
/// this the conformance crosses into main-actor code, which is a data race in
/// the Swift 6 language mode.
@MainActor
protocol RunningQueriesPopoverDelegate: AnyObject {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String)
    /// Cancel All: every query the list shows.
    func runningQueriesPopoverDidRequestCancelAll(_ vc: RunningQueriesPopoverVC)
}

/// Popover content showing one row per in-flight query for a tab: where it is
/// in the editor, the start of its statement, how long it has run, and its own
/// cancel button; with two or more, a Cancel All button under the rows.
final class RunningQueriesPopoverVC: NSViewController {

    /// The popover's width. Wide enough for a useful start of a statement.
    static let width: CGFloat = 300

    weak var delegate: RunningQueriesPopoverDelegate?

    private let session: WindowSession
    private let tabId: String
    private var subscription: AnyCancellable?
    private var elapsedTimer: Timer?

    private let headerLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private let cancelAllButton = NSButton()
    private var rowsById: [String: RunningQueryRow] = [:]
    private var orderedIds: [String] = []
    private var stackBottom: NSLayoutConstraint?
    private var buttonTop: NSLayoutConstraint?
    private var buttonBottom: NSLayoutConstraint?

    init(session: WindowSession, tabId: String) {
        self.session = session
        self.tabId = tabId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.spacing = 4
        // `.leading`, not `.width`: an NSStackView rejects `.width` and the
        // property reads back as `.notAnAttribute` — see
        // NSStackView+SpanFullWidth.swift. The rows here arrive in
        // `reconcileRows`, long after this runs, so the shared span helper
        // would reach none of them; each row is pinned to this stack's width
        // as it is added instead.
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        cancelAllButton.title = String(localized: "Cancel All")
        cancelAllButton.bezelStyle = .push
        cancelAllButton.controlSize = .small
        cancelAllButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cancelAllButton.target = self
        cancelAllButton.action = #selector(cancelAllTapped)
        cancelAllButton.setAccessibilityIdentifier("runningQueries.cancelAll")
        cancelAllButton.translatesAutoresizingMaskIntoConstraints = false
        cancelAllButton.isHidden = true

        root.addSubview(headerLabel)
        root.addSubview(stackView)
        root.addSubview(cancelAllButton)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            stackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            cancelAllButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        // The bottom edge follows the Cancel All button when it shows, the
        // rows when it does not.
        stackBottom = stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        buttonTop = cancelAllButton.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 8)
        buttonBottom = cancelAllButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        stackBottom?.isActive = true

        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reconcileRows()
        startElapsedTimer()
        subscription = session.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileRows() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        subscription?.cancel()
        subscription = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func tickElapsed() {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return }
        let now = CACurrentMediaTime()
        for q in tab.runningQueries {
            rowsById[q.id]?.setElapsed(DurationText.clock(seconds: now - q.startTime))
        }
    }

    private func reconcileRows() {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else {
            dismissPopover()
            return
        }
        let queries = tab.runningQueries.sorted { $0.startTime < $1.startTime }

        switch queries.count {
        case 0:  headerLabel.stringValue = String(localized: "No queries running")
        case 1:  headerLabel.stringValue = String(localized: "1 query running")
        default: headerLabel.stringValue = String(localized: "\(queries.count) queries running")
        }
        setCancelAllVisible(queries.count > 1)

        let now = CACurrentMediaTime()
        let presentIds = Set(queries.map { $0.id })

        // Remove rows for queries no longer running.
        for id in orderedIds where !presentIds.contains(id) {
            if let row = rowsById.removeValue(forKey: id) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    row.animator().alphaValue = 0
                }, completionHandler: {
                    self.stackView.removeArrangedSubview(row)
                    row.removeFromSuperview()
                })
            }
        }
        orderedIds.removeAll { !presentIds.contains($0) }

        // Add rows for new queries, in startTime order.
        for q in queries where rowsById[q.id] == nil {
            let row = RunningQueryRow(query: q,
                                      elapsed: DurationText.clock(seconds: now - q.startTime)) { [weak self] id in
                guard let self else { return }
                self.rowsById[id]?.markCancelling()
                self.delegate?.runningQueriesPopover(self, didRequestCancelQueryId: id)
            }
            rowsById[q.id] = row
            stackView.addArrangedSubview(row)
            // A RunningQueryRow states no width of its own — its label is
            // pinned to its leading edge and its cancel button to its trailing
            // edge, which only reads correctly at the stack's full width. The
            // stack's own width is fixed (`RunningQueriesPopoverVC.width`), so a row
            // measures full width today either way; this says the requirement
            // rather than inheriting it from that.
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            orderedIds.append(q.id)
        }
    }

    /// The rows in list order, and whether Cancel All shows (for tests).
    var rows: [RunningQueryRow] { orderedIds.compactMap { rowsById[$0] } }
    var isCancelAllVisible: Bool { !cancelAllButton.isHidden }
    /// Press Cancel All, as a click does.
    func pressCancelAll() { cancelAllButton.performClick(nil) }

    private func setCancelAllVisible(_ visible: Bool) {
        guard cancelAllButton.isHidden == visible else { return }
        cancelAllButton.isHidden = !visible
        stackBottom?.isActive = !visible
        buttonTop?.isActive = visible
        buttonBottom?.isActive = visible
    }

    @objc private func cancelAllTapped() {
        for row in rowsById.values { row.markCancelling() }
        cancelAllButton.isEnabled = false
        delegate?.runningQueriesPopoverDidRequestCancelAll(self)
    }

    private func dismissPopover() {
        self.dismiss(nil)
    }
}

/// Single popover row: "Lines X–Y" left, "M:SS" right, cancel button trailing,
/// and under them the start of the statement on one line.
final class RunningQueryRow: NSView {

    private let queryId: String
    private let onCancel: (String) -> Void
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let linesLabel: NSTextField
    /// The start of the statement, one line, cut at the end.
    let previewLabel: NSTextField
    private let cancelButton = NSButton()
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    private(set) var isCancelling = false

    init(query: RunningQuery, elapsed: String, onCancel: @escaping (String) -> Void) {
        self.queryId = query.id
        self.onCancel = onCancel
        let linesText: String
        if query.segmentIndex == -1 {
            linesText = String(localized: "Direct SQL")
        } else if query.lineRange.lowerBound == query.lineRange.upperBound {
            linesText = String(localized: "Line \(query.lineRange.lowerBound)")
        } else {
            linesText = String(localized: "Lines \(query.lineRange.lowerBound)–\(query.lineRange.upperBound)")
        }
        self.linesLabel = NSTextField(labelWithString: linesText)
        // `normalizedSQL` is already one line (whitespace runs collapsed).
        // DisplayEscape keeps a bidi override or a control character in the
        // statement from rearranging the row.
        self.previewLabel = NSTextField(labelWithString: DisplayEscape.escaped(query.normalizedSQL))
        super.init(frame: .zero)

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.setAccessibilityLabel(query.normalizedSQL)

        linesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        linesLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.stringValue = elapsed
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .recessed
        cancelButton.isBordered = false
        cancelButton.title = ""
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                     accessibilityDescription: String(localized: "Cancel"))?
            .withSymbolConfiguration(iconConfig)
        cancelButton.contentTintColor = .systemRed
        cancelButton.refusesFirstResponder = true
        cancelButton.imageScaling = .scaleNone
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(linesLabel)
        addSubview(elapsedLabel)
        addSubview(cancelButton)
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            linesLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            linesLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: linesLabel.bottomAnchor, constant: 2),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            elapsedLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            elapsedLabel.centerYAnchor.constraint(equalTo: linesLabel.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 18),
            cancelButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setElapsed(_ text: String) {
        elapsedLabel.stringValue = text
    }

    func markCancelling() {
        guard !isCancelling else { return }
        isCancelling = true
        cancelButton.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                     accessibilityDescription: String(localized: "Cancelled"))?
            .withSymbolConfiguration(iconConfig)
        cancelButton.contentTintColor = .tertiaryLabelColor
        cancelButton.isEnabled = false
        linesLabel.textColor = .tertiaryLabelColor
        elapsedLabel.textColor = .tertiaryLabelColor
    }

    @objc private func cancelTapped() {
        onCancel(queryId)
    }
}
