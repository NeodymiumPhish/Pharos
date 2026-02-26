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

        // -- Status Labels --

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

        let labelStack = NSStackView(views: [statusLabel, pinSourceLabel, historyContextLabel])
        labelStack.orientation = .horizontal
        labelStack.spacing = 8
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // -- Find Controls (inline, hidden by default) --

        findControlsStack.orientation = .horizontal
        findControlsStack.spacing = 4
        findControlsStack.isHidden = true
        findControlsStack.setContentHuggingPriority(.required, for: .horizontal)
        findControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in results..."
        findField.sendsSearchStringImmediately = true
        findField.font = .systemFont(ofSize: 12)

        filterToggleButton.setButtonType(.pushOnPushOff)
        filterToggleButton.title = "Filter"
        filterToggleButton.bezelStyle = .recessed
        filterToggleButton.font = .systemFont(ofSize: 11)
        filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        filterToggleButton.toolTip = "Filter rows to matches only"

        findClearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        findClearButton.bezelStyle = .recessed
        findClearButton.isBordered = false
        findClearButton.translatesAutoresizingMaskIntoConstraints = false
        findClearButton.contentTintColor = .tertiaryLabelColor
        findClearButton.isHidden = true

        findCountLabel.translatesAutoresizingMaskIntoConstraints = false
        findCountLabel.font = .systemFont(ofSize: 11)
        findCountLabel.textColor = .secondaryLabelColor
        findCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        findPrevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        findPrevButton.bezelStyle = .recessed
        findPrevButton.isBordered = false
        findPrevButton.translatesAutoresizingMaskIntoConstraints = false

        findNextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        findNextButton.bezelStyle = .recessed
        findNextButton.isBordered = false
        findNextButton.translatesAutoresizingMaskIntoConstraints = false

        findCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        findCloseButton.bezelStyle = .recessed
        findCloseButton.isBordered = false
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false

        findControlsStack.addArrangedSubview(findField)
        findControlsStack.addArrangedSubview(filterToggleButton)
        findControlsStack.addArrangedSubview(findClearButton)
        findControlsStack.addArrangedSubview(findCountLabel)
        findControlsStack.addArrangedSubview(findPrevButton)
        findControlsStack.addArrangedSubview(findNextButton)
        findControlsStack.addArrangedSubview(findCloseButton)

        NSLayoutConstraint.activate([
            findClearButton.widthAnchor.constraint(equalToConstant: 20),
            findPrevButton.widthAnchor.constraint(equalToConstant: 20),
            findNextButton.widthAnchor.constraint(equalToConstant: 20),
            findCloseButton.widthAnchor.constraint(equalToConstant: 20),
        ])

        // -- Action Buttons --

        // Target/action set in loadView() after sortController creation
        configureToolbarButtonAppearance(resetSortButton, symbol: "arrow.up.arrow.down.circle.fill", tooltip: "Reset Sort")
        resetSortButton.contentTintColor = .controlAccentColor
        resetSortButton.isHidden = true

        configureToolbarButtonAppearance(resetFiltersButton, symbol: "line.3.horizontal.decrease.circle.fill", tooltip: "Reset Column Filters")
        resetFiltersButton.contentTintColor = .controlAccentColor
        resetFiltersButton.isHidden = true
        resetFiltersButton.target = self
        resetFiltersButton.action = #selector(resetAllColumnFilters)

        configureToolbarButton(pinButton, symbol: "pin",
                               action: #selector(togglePin), tooltip: "Pin Results")
        configureToolbarButton(findToolbarButton, symbol: "magnifyingglass",
                               action: #selector(showFind), tooltip: "Find (Cmd+F)")
        // Copy/export button icons/style set here; target/action set in loadView() after helper creation
        configureToolbarButtonAppearance(copyButton, symbol: "doc.on.doc", tooltip: "Copy")
        configureToolbarButtonAppearance(exportButton, symbol: "square.and.arrow.up", tooltip: "Export")

        let buttonStack = NSStackView(views: [resetSortButton, resetFiltersButton, pinButton, findToolbarButton, copyButton, exportButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2
        buttonStack.setHuggingPriority(.required, for: .horizontal)
        buttonStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Root Layout: labelStack | findControlsStack | buttonStack --

        let rootStack = NSStackView(views: [labelStack, findControlsStack, buttonStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        toolbarBar.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: toolbarBar.leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: toolbarBar.trailingAnchor, constant: -8),
            rootStack.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),

            // Find field: 25% of toolbar width
            findField.widthAnchor.constraint(equalTo: toolbarBar.widthAnchor, multiplier: 0.25),
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
