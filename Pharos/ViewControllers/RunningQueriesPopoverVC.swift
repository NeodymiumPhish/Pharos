import AppKit
import Combine

/// Delegate for popover row actions. The owning `EditorPaneVC` forwards
/// cancel requests to its own delegate so the `ContentViewController`
/// stays the single owner of cancellation logic.
protocol RunningQueriesPopoverDelegate: AnyObject {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String)
}

/// Popover content showing one row per in-flight query for a tab.
final class RunningQueriesPopoverVC: NSViewController {

    weak var delegate: RunningQueriesPopoverDelegate?

    private let stateManager: AppStateManager
    private let tabId: String
    private var subscription: AnyCancellable?
    private var elapsedTimer: Timer?

    private let headerLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private var rowsById: [String: RunningQueryRow] = [:]
    private var orderedIds: [String] = []

    init(stateManager: AppStateManager, tabId: String) {
        self.stateManager = stateManager
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
        stackView.alignment = .width
        stackView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerLabel)
        root.addSubview(stackView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            stackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            root.widthAnchor.constraint(equalToConstant: 260),
        ])

        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reconcileRows()
        startElapsedTimer()
        subscription = stateManager.$tabs
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
        guard let tab = stateManager.tabs.first(where: { $0.id == tabId }) else { return }
        let now = CACurrentMediaTime()
        for q in tab.runningQueries {
            rowsById[q.id]?.setElapsed(ContentViewController.formatElapsed(now - q.startTime))
        }
    }

    private func reconcileRows() {
        guard let tab = stateManager.tabs.first(where: { $0.id == tabId }) else {
            dismissPopover()
            return
        }
        let queries = tab.runningQueries.sorted { $0.startTime < $1.startTime }

        // Auto-dismiss when only one (or none) remains — the toolbar button
        // takes over again for 0/1.
        if queries.count <= 1 {
            dismissPopover()
            return
        }

        headerLabel.stringValue = "\(queries.count) queries running"

        let now = CACurrentMediaTime()
        let presentIds = Set(queries.map { $0.id })

        // Remove rows for queries no longer running.
        for id in orderedIds where !presentIds.contains(id) {
            if let row = rowsById.removeValue(forKey: id) {
                stackView.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
        orderedIds.removeAll { !presentIds.contains($0) }

        // Add rows for new queries, in startTime order.
        for q in queries where rowsById[q.id] == nil {
            let row = RunningQueryRow(query: q,
                                      elapsed: ContentViewController.formatElapsed(now - q.startTime)) { [weak self] id in
                guard let self else { return }
                self.delegate?.runningQueriesPopover(self, didRequestCancelQueryId: id)
            }
            rowsById[q.id] = row
            stackView.addArrangedSubview(row)
            orderedIds.append(q.id)
        }
    }

    private func dismissPopover() {
        self.dismiss(nil)
    }
}

/// Single popover row: "Lines X–Y" left, "M:SS" right, cancel button trailing.
private final class RunningQueryRow: NSView {

    private let queryId: String
    private let onCancel: (String) -> Void
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let linesLabel: NSTextField

    init(query: RunningQuery, elapsed: String, onCancel: @escaping (String) -> Void) {
        self.queryId = query.id
        self.onCancel = onCancel
        let linesText: String
        if query.segmentIndex == -1 {
            linesText = "Direct SQL"
        } else if query.lineRange.lowerBound == query.lineRange.upperBound {
            linesText = "Line \(query.lineRange.lowerBound)"
        } else {
            linesText = "Lines \(query.lineRange.lowerBound)–\(query.lineRange.upperBound)"
        }
        self.linesLabel = NSTextField(labelWithString: linesText)
        super.init(frame: .zero)

        linesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        linesLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.stringValue = elapsed
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton()
        cancelButton.bezelStyle = .recessed
        cancelButton.isBordered = false
        cancelButton.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")?
            .withSymbolConfiguration(config)
        cancelButton.contentTintColor = .systemRed
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(linesLabel)
        addSubview(elapsedLabel)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            linesLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            linesLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            elapsedLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            elapsedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

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

    @objc private func cancelTapped() {
        onCancel(queryId)
    }
}
