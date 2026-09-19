import AppKit
import Combine

/// The query plan a result tab of kind "plan" shows, in place of the grid.
///
/// One `NSOutlineView` over the `PlanNode` tree, expanded, with the node that
/// accounts for the most work selected and scrolled into view — the first
/// question anyone asks a plan is "where did the time go?", so the view answers
/// it before the user reads a row. A header line above it carries the figures
/// that belong to the plan as a whole, and a button copies the server's own
/// JSON so it can be pasted into another tool.
final class PlanViewVC: NSViewController {

    // MARK: Column identifiers

    private enum Column {
        static let node = NSUserInterfaceItemIdentifier("PlanNode")
        static let rows = NSUserInterfaceItemIdentifier("PlanRows")
        static let time = NSUserInterfaceItemIdentifier("PlanTime")
        static let cost = NSUserInterfaceItemIdentifier("PlanCost")
        static let share = NSUserInterfaceItemIdentifier("PlanShare")
    }

    // MARK: State

    private(set) var plan: QueryPlan?
    private var planJSON: String = ""
    private var isAnalyze = false
    /// `QueryPlan.totalWeight`, cached: every row asks for it while drawing.
    private var totalWeight: Double = 0

    // MARK: Views

    private let headerLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    // MARK: The generated summary

    private let summaryView = PlanSummaryView()
    private let summarizer = PlanSummarizer()
    /// The generation in flight, so a second plan cancels the first rather
    /// than racing it into the same view.
    private var summaryTask: Task<Void, Never>?
    /// The prompt the summary on screen answers. A repeat of the same plan
    /// must not spend a second generation on it.
    private var summarizedPrompt: String?
    private var availabilityCancellable: AnyCancellable?

    /// The outline starts under the header row when there is no summary, and
    /// under the summary when there is one. Two constraints rather than a
    /// collapsing height: a hidden view keeps its own internal constraints, so
    /// a zero-height override would break one of them on every plan.
    private var scrollTopBelowHeader: NSLayoutConstraint!
    private var scrollTopBelowSummary: NSLayoutConstraint!

    override func loadView() {
        let container = NSView()
        view = container

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = String(localized: "Copy Plan JSON")
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyPlanJSON)
        copyButton.toolTip = String(localized: "Copy the server's EXPLAIN (FORMAT JSON) output.")

        for (identifier, title, width) in [
            (Column.node, String(localized: "Node"), CGFloat(320)),
            (Column.rows, String(localized: "Rows"), CGFloat(140)),
            (Column.time, String(localized: "Time"), CGFloat(90)),
            (Column.cost, String(localized: "Cost"), CGFloat(130)),
            (Column.share, String(localized: "Share"), CGFloat(110)),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsColumnResizing = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel(String(localized: "Query plan"))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        summaryView.onRetry = { [weak self] in self?.regenerateSummary() }

        container.addSubview(headerLabel)
        container.addSubview(copyButton)
        container.addSubview(summaryView)
        container.addSubview(scrollView)

        scrollTopBelowHeader = scrollView.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 6)
        scrollTopBelowSummary = scrollView.topAnchor.constraint(equalTo: summaryView.bottomAnchor)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),

            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            summaryView.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 6),
            summaryView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            summaryView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollTopBelowHeader,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // The feature can be switched off while a plan is on screen, so the
        // block follows availability rather than being decided once.
        availabilityCancellable = ModelAvailability.shared.publisher(for: .summarisePlans)
            .sink { [weak self] available in
                MainActor.assumeIsolated { self?.availabilityChanged(to: available) }
            }
    }

    // MARK: - Presenting a plan

    /// Show `plan`. `json` is the server's own text, kept for the copy button.
    func show(plan: QueryPlan, json: String, isAnalyze: Bool) {
        // A repeat of the plan already on screen would otherwise throw away the
        // user's scroll position and re-select the slowest row on every tab
        // switch back to this result.
        let isSamePlan = (self.planJSON == json && self.plan != nil)
        self.plan = plan
        self.planJSON = json
        self.isAnalyze = isAnalyze
        self.totalWeight = plan.totalWeight

        headerLabel.stringValue = Self.headerText(for: plan, isAnalyze: isAnalyze)
        headerLabel.toolTip = headerLabel.stringValue

        // Both kinds of plan are summarised. An estimate-only plan is the one
        // the user is most likely to need read to them, because it has no
        // measured times to rank its steps by eye.
        startSummaryIfNeeded(for: plan)

        guard !isSamePlan else { return }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        selectSlowestNode()
    }

    /// The whole-plan figures: measured when the statement was analyzed,
    /// estimated when it was not.
    static func headerText(for plan: QueryPlan, isAnalyze: Bool) -> String {
        var parts: [String] = []
        if let planning = plan.planningTimeMs {
            parts.append(String(localized: "Planning \(PlanText.ms(planning))"))
        }
        if isAnalyze, let execution = plan.executionTimeMs {
            parts.append(String(localized: "Execution \(PlanText.ms(execution))"))
        }
        if !isAnalyze || plan.executionTimeMs == nil {
            parts.append(String(localized: "Estimated cost \(PlanText.cost(plan.root.startupCost))..\(PlanText.cost(plan.root.totalCost))"))
        }
        parts.append(CountedNounText.phrase(plan.nodeCount, "node"))
        return parts.joined(separator: " · ")
    }

    /// Select the node that accounts for the most work and bring it on screen.
    private func selectSlowestNode() {
        guard let slowest = plan?.slowestNode else { return }
        let row = outlineView.row(forItem: slowest)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - The generated summary

    /// Ask the model to read this plan, unless it has already read it.
    ///
    /// `available` is passed in by the availability sink and read from
    /// `ModelAvailability` by everyone else. That is not a convenience: a
    /// `@Published` property notifies its subscribers on `willSet`, so a sink
    /// that reaches back for `ModelAvailability.shared.isAvailable` reads the
    /// value being REPLACED. Measured — switching the feature back on in
    /// Settings left the plan with no summary until the next plan arrived,
    /// because this guard still saw `false`.
    private func startSummaryIfNeeded(for plan: QueryPlan, available: Bool? = nil) {
        guard available ?? ModelAvailability.shared.isAvailable(for: .summarisePlans) else {
            setSummaryVisible(false)
            return
        }
        let prompt = PlanSummaryPrompt.build(plan: plan)
        // Switching back to a result tab re-shows its plan. The summary it
        // already carries is the answer to the same prompt, so leave it.
        guard prompt != summarizedPrompt else { return }
        generateSummary(prompt: prompt)
    }

    /// Ask again for the plan on screen — the Retry button.
    private func regenerateSummary() {
        guard let plan, ModelAvailability.shared.isAvailable(for: .summarisePlans) else { return }
        generateSummary(prompt: PlanSummaryPrompt.build(plan: plan))
    }

    private func generateSummary(prompt: String) {
        summaryTask?.cancel()
        summarizedPrompt = prompt
        setSummaryVisible(true)
        summaryView.promptHash = ModelFeedbackStore.promptHash(prompt)
        summaryView.setState(.working)

        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.summarizer.summarize(prompt: prompt)
                guard !Task.isCancelled else { return }
                self.summaryView.setState(.answered(summary))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.intelligence.error(
                    "Plan summary failed: \(error.localizedDescription, privacy: .public)")
                // The prompt is forgotten so Retry is a real retry and not a
                // no-op against a remembered answer.
                self.summarizedPrompt = nil
                self.summaryView.setState(
                    .failed(String(localized: "The plan could not be summarised.")))
            }
        }
    }

    /// Show or hide the block, moving the outline up into the space when it
    /// goes. Called on every availability change as well as per plan.
    private func setSummaryVisible(_ visible: Bool) {
        summaryView.isHidden = !visible
        guard scrollTopBelowSummary.isActive != visible else { return }
        scrollTopBelowSummary.isActive = false
        scrollTopBelowHeader.isActive = false
        (visible ? scrollTopBelowSummary : scrollTopBelowHeader).isActive = true
    }

    private func availabilityChanged(to available: Bool) {
        guard isViewLoaded else { return }
        if available {
            if let plan { startSummaryIfNeeded(for: plan, available: true) }
        } else {
            summaryTask?.cancel()
            summaryTask = nil
            summarizedPrompt = nil
            summaryView.setState(.idle)
            setSummaryVisible(false)
        }
    }

    @objc private func copyPlanJSON() {
        guard !planJSON.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(planJSON, forType: .string)
        Toast.show(in: view, message: String(localized: "Plan JSON copied."), style: .success)
    }
}

// MARK: - Data source

extension PlanViewVC: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return plan == nil ? 0 : 1 }
        return (item as? PlanNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? PlanNode { return node.children[index] }
        // Only reachable when `numberOfChildrenOfItem: nil` answered 1, which
        // requires a plan; the placeholder keeps the signature honest without a
        // force unwrap.
        return plan?.root ?? PlanNode([:], path: "0")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? PlanNode)?.children.isEmpty ?? true)
    }
}

// MARK: - Delegate

extension PlanViewVC: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PlanNode, let column = tableColumn else { return nil }

        if column.identifier == Column.share {
            let bar = outlineView.makeView(withIdentifier: Column.share, owner: self) as? PlanShareBarView
                ?? {
                    let made = PlanShareBarView()
                    made.identifier = Column.share
                    return made
                }()
            bar.share = node.share(of: totalWeight)
            return bar
        }

        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? Self.makeTextCell(identifier: column.identifier)
        cell.textField?.stringValue = text(for: node, column: column.identifier)
        cell.textField?.alignment = column.identifier == Column.node ? .natural : .right
        cell.toolTip = tooltip(for: node)
        // The whole row's sentence goes on the FIRST cell, not on the row view:
        // AppKit answers for an `NSTableRowView` with its own AXRow proxy, and a
        // label set on the view does not reach it (measured — the row came back
        // with an empty AXDescription). A cell's label does reach VoiceOver, and
        // the node column is the first thing read on the row.
        if column.identifier == Column.node {
            cell.textField?.setAccessibilityLabel(accessibilityText(for: node))
        } else {
            cell.textField?.setAccessibilityLabel(nil)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowIdentifier = NSUserInterfaceItemIdentifier("PlanRow")
        let row = outlineView.makeView(withIdentifier: rowIdentifier, owner: self) as? NSTableRowView
            ?? {
                let made = NSTableRowView()
                made.identifier = rowIdentifier
                return made
            }()
        if let node = item as? PlanNode {
            // One sentence per row, so a screen reader reads the node and its
            // numbers together instead of four disconnected cells.
            row.setAccessibilityLabel(accessibilityText(for: node))
        }
        return row
    }

    // MARK: Cell text

    private func text(for node: PlanNode, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.node:
            return node.displayName
        case Column.rows:
            return PlanText.rows(node)
        case Column.time:
            guard let total = node.totalTimeMs else { return "" }
            return PlanText.ms(total)
        case Column.cost:
            return "\(PlanText.cost(node.startupCost))..\(PlanText.cost(node.totalCost))"
        default:
            return ""
        }
    }

    private func tooltip(for node: PlanNode) -> String? {
        let conditions = node.conditions
        guard !conditions.isEmpty else { return nil }
        return conditions.map { "\($0.label): \($0.text)" }.joined(separator: "\n")
    }

    private func accessibilityText(for node: PlanNode) -> String {
        var parts = [node.displayName, PlanText.rows(node)]
        if let total = node.totalTimeMs {
            parts.append(String(localized: "\(PlanText.ms(total)), \(PlanText.percent(node.share(of: totalWeight))) of the plan"))
        } else {
            parts.append(String(localized: "cost \(PlanText.cost(node.totalCost)), \(PlanText.percent(node.share(of: totalWeight))) of the plan"))
        }
        for condition in node.conditions { parts.append("\(condition.label): \(condition.text)") }
        return parts.joined(separator: ", ")
    }

    private static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = identifier == Column.node
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - The share bar

/// A rounded bar whose width is the node's share of the whole plan.
///
/// With Differentiate Without Color on, the bar alone is a colour-only signal
/// against the row background, so the percentage is drawn beside it as text.
final class PlanShareBarView: NSView {

    var share: Double = 0 {
        didSet { if share != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: AccessibilityDisplay.didChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func accessibilityDisplayChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let differentiate = AccessibilityDisplay.shared.differentiateWithoutColor
        let text = PlanText.percent(share)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textWidth = differentiate ? (text as NSString).size(withAttributes: attributes).width + 6 : 0

        let barHeight: CGFloat = 8
        let track = NSRect(
            x: 2,
            y: (bounds.height - barHeight) / 2,
            width: max(0, bounds.width - 4 - textWidth),
            height: barHeight
        )
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let filledWidth = track.width * CGFloat(min(1, max(0, share)))
        if filledWidth > 0.5 {
            var filled = track
            filled.size.width = max(filledWidth, barHeight)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }

        if differentiate {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: track.maxX + 6, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

// MARK: - Number text

/// The plan view's number formatting, in one place so the outline, the header
/// and the accessibility description cannot disagree about a figure.
enum PlanText {

    /// "3.4 ms" — two fraction digits below 10 ms, where the difference between
    /// 0.12 and 0.13 is the whole story, and one above it, where it is noise.
    static func ms(_ value: Double) -> String {
        let digits = value < 10 ? 2 : 1
        return String(localized: "\(value.formatted(.number.precision(.fractionLength(digits)))) ms")
    }

    /// "18.10" — costs are always two places, the way PostgreSQL prints them.
    static func cost(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func count(_ value: Double) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)))
    }

    /// "72%" — whole percent, except below 1% where that would read as zero.
    static func percent(_ share: Double) -> String {
        let value = min(1, max(0, share))
        let digits = (value > 0 && value < 0.01) ? 1 : 0
        return (value * 100).formatted(.number.precision(.fractionLength(digits))) + "%"
    }

    /// "1,200 → 1,187", or just the estimate when the plan has no actuals.
    /// A node that ran more than once reports rows PER LOOP, so the loop count
    /// is shown beside them rather than being multiplied into a figure the
    /// server never printed.
    static func rows(_ node: PlanNode) -> String {
        let estimate = count(node.planRows)
        guard let actual = node.actualRows else { return estimate }
        var text = "\(estimate) → \(count(actual))"
        if node.loops > 1 { text += " ×\(node.loops.formatted())" }
        return text
    }
}
