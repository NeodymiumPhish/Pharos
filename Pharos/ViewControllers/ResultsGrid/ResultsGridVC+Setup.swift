import AppKit

// MARK: - Scroll View with Non-Overlapping Scrollers

/// NSScrollView subclass that positions scrollers outside the content area
/// instead of overlaying them on top of the document view.
class InsetScrollView: NSScrollView {
    override func tile() {
        super.tile()

        // Only adjust the clip view's SIZE to make room for scrollers.
        // Do NOT change its origin -- super.tile() positions it correctly
        // relative to the floating header. Moving it creates a gap.
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let hasVert = hasVerticalScroller && !(verticalScroller?.isHidden ?? true)
        let hasHoriz = hasHorizontalScroller && !(horizontalScroller?.isHidden ?? true)
        let vertW = hasVert ? w : 0
        let horizH = hasHoriz ? w : 0

        var clipFrame = contentView.frame
        clipFrame.size.width = max(0, bounds.width - vertW)
        clipFrame.size.height = max(0, clipFrame.size.height - horizH)
        contentView.frame = clipFrame

        // Vertical scroller: starts below the header, spans data rows only
        let headerH = (documentView as? NSTableView)?.headerView?.frame.height ?? 0
        if hasVert, let vs = verticalScroller {
            vs.frame = NSRect(
                x: bounds.width - vertW,
                y: headerH,
                width: vertW,
                height: max(0, clipFrame.maxY - headerH)
            )
        }

        // Horizontal scroller: right below the clip view
        if hasHoriz, let hs = horizontalScroller {
            hs.frame = NSRect(x: 0, y: clipFrame.maxY, width: clipFrame.width, height: horizH)
        }
    }
}

// MARK: - View Setup

extension ResultsGridVC {

    // MARK: - Toolbar Setup

    func setupToolbar() {
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarBar.isHidden = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinSourceLabel.translatesAutoresizingMaskIntoConstraints = false
        pinSourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pinSourceLabel.textColor = .systemOrange
        pinSourceLabel.isHidden = true
        pinSourceLabel.setContentHuggingPriority(.required, for: .horizontal)

        historyContextLabel.translatesAutoresizingMaskIntoConstraints = false
        historyContextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        historyContextLabel.textColor = .systemIndigo
        historyContextLabel.isHidden = true
        historyContextLabel.lineBreakMode = .byTruncatingTail
        historyContextLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        historyContextLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)

        // Target/action set in loadView() after sortController creation
        configureToolbarButtonAppearance(resetSortButton, symbol: "arrow.up.arrow.down.circle.fill", tooltip: "Reset Sort")
        resetSortButton.contentTintColor = .controlAccentColor
        resetSortButton.isHidden = true

        configureToolbarButton(pinButton, symbol: "pin",
                               action: #selector(togglePin), tooltip: "Pin Results")
        configureToolbarButton(findToolbarButton, symbol: "magnifyingglass",
                               action: #selector(showFind), tooltip: "Find (Cmd+F)")
        // Copy/export button icons/style set here; target/action set in loadView() after helper creation
        configureToolbarButtonAppearance(copyButton, symbol: "doc.on.doc", tooltip: "Copy")
        configureToolbarButtonAppearance(exportButton, symbol: "square.and.arrow.up", tooltip: "Export")

        let buttonStack = NSStackView(views: [resetSortButton, pinButton, findToolbarButton, copyButton, exportButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setHuggingPriority(.required, for: .horizontal)

        let labelStack = NSStackView(views: [statusLabel, pinSourceLabel, historyContextLabel])
        labelStack.orientation = .horizontal
        labelStack.spacing = 8
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        toolbarBar.addSubview(labelStack)
        toolbarBar.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: toolbarBar.leadingAnchor, constant: 8),
            labelStack.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: toolbarBar.trailingAnchor, constant: -8),
            buttonStack.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
        ])
    }

    func configureToolbarButton(_ button: NSButton, symbol: String, action: Selector, tooltip: String) {
        configureToolbarButtonAppearance(button, symbol: symbol, tooltip: tooltip)
        button.target = self
        button.action = action
    }

    func configureToolbarButtonAppearance(_ button: NSButton, symbol: String, tooltip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Find Bar Setup

    func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true

        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in results..."
        findField.sendsSearchStringImmediately = true
        findField.font = .systemFont(ofSize: 12)
        // target/action/delegate set by ResultsFindController

        filterToggleButton.setButtonType(.pushOnPushOff)
        filterToggleButton.title = "Filter"
        filterToggleButton.bezelStyle = .recessed
        filterToggleButton.font = .systemFont(ofSize: 11)
        filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        filterToggleButton.toolTip = "Filter rows to matches only"
        // target/action set by ResultsFindController

        findClearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        findClearButton.bezelStyle = .recessed
        findClearButton.isBordered = false
        findClearButton.translatesAutoresizingMaskIntoConstraints = false
        findClearButton.contentTintColor = .tertiaryLabelColor
        findClearButton.isHidden = true
        // target/action set by ResultsFindController

        findCountLabel.translatesAutoresizingMaskIntoConstraints = false
        findCountLabel.font = .systemFont(ofSize: 11)
        findCountLabel.textColor = .secondaryLabelColor
        findCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        findPrevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        findPrevButton.bezelStyle = .recessed
        findPrevButton.isBordered = false
        findPrevButton.translatesAutoresizingMaskIntoConstraints = false
        // target/action set by ResultsFindController

        findNextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        findNextButton.bezelStyle = .recessed
        findNextButton.isBordered = false
        findNextButton.translatesAutoresizingMaskIntoConstraints = false
        // target/action set by ResultsFindController

        findCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        findCloseButton.bezelStyle = .recessed
        findCloseButton.isBordered = false
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false
        // target/action set by ResultsFindController

        findBar.addSubview(findField)
        findBar.addSubview(filterToggleButton)
        findBar.addSubview(findClearButton)
        findBar.addSubview(findCountLabel)
        findBar.addSubview(findPrevButton)
        findBar.addSubview(findNextButton)
        findBar.addSubview(findCloseButton)

        NSLayoutConstraint.activate([
            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            filterToggleButton.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 6),
            filterToggleButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),

            findClearButton.leadingAnchor.constraint(equalTo: filterToggleButton.trailingAnchor, constant: 4),
            findClearButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findClearButton.widthAnchor.constraint(equalToConstant: 20),

            findCountLabel.leadingAnchor.constraint(equalTo: findClearButton.trailingAnchor, constant: 8),
            findCountLabel.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),

            findPrevButton.leadingAnchor.constraint(equalTo: findCountLabel.trailingAnchor, constant: 4),
            findPrevButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findPrevButton.widthAnchor.constraint(equalToConstant: 20),

            findNextButton.leadingAnchor.constraint(equalTo: findPrevButton.trailingAnchor, constant: 2),
            findNextButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findNextButton.widthAnchor.constraint(equalToConstant: 20),

            findCloseButton.leadingAnchor.constraint(greaterThanOrEqualTo: findNextButton.trailingAnchor, constant: 8),
            findCloseButton.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findCloseButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findCloseButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Load More Bar Setup

    func setupLoadMoreBar() {
        loadMoreBar.translatesAutoresizingMaskIntoConstraints = false
        loadMoreBar.isHidden = true

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreTapped)
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false

        loadMoreSpinner.style = .spinning
        loadMoreSpinner.controlSize = .small
        loadMoreSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadMoreSpinner.isHidden = true

        loadMoreBar.addSubview(loadMoreButton)
        loadMoreBar.addSubview(loadMoreSpinner)

        NSLayoutConstraint.activate([
            loadMoreButton.centerXAnchor.constraint(equalTo: loadMoreBar.centerXAnchor),
            loadMoreButton.centerYAnchor.constraint(equalTo: loadMoreBar.centerYAnchor),

            loadMoreSpinner.leadingAnchor.constraint(equalTo: loadMoreButton.trailingAnchor, constant: 8),
            loadMoreSpinner.centerYAnchor.constraint(equalTo: loadMoreBar.centerYAnchor),
        ])
    }
}
