import AppKit

// MARK: - View Setup

extension ResultsGridVC {

    // MARK: - Load More Bar Setup

    /// The Load More / Load All controls, for the owner's action bar (beside
    /// the row count they act on, which says "(more available)"). Small
    /// accessory-bar buttons, as the bar's other controls are small (Apple HIG,
    /// *Buttons*: a bar's buttons match its size); while Load All runs, a
    /// determinate bar, its count and Cancel follow them.
    func setupLoadMoreBar() {
        loadControls.isHidden = true

        for (button, action, id) in [(loadMoreButton, #selector(loadMoreTapped), "results.loadMore"),
                                     (loadAllButton, #selector(loadAllTapped), "results.loadAll")] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
        }
        loadMoreButton.toolTip = "Load More Rows: fetch the next page. Each page is a new execution wrapped in LIMIT/OFFSET."
        loadAllButton.toolTip = "Load All Rows: re-run the statement through a server cursor and replace the result with one consistent snapshot, up to the Load All limit (Settings ▸ Query)."

        loadMoreSpinner.style = .spinning
        loadMoreSpinner.controlSize = .small
        loadMoreSpinner.isHidden = true

        // The Load All progress trio. A determinate bar, because the core
        // reports a running total per chunk and the cap is a known maximum —
        // a spinner during a half-million-row load says only "still going".
        loadAllProgress.style = .bar
        loadAllProgress.isIndeterminate = false
        loadAllProgress.controlSize = .small
        loadAllProgress.minValue = 0
        loadAllProgress.maxValue = 1
        loadAllProgress.doubleValue = 0
        loadAllProgress.isHidden = true
        loadAllProgress.setAccessibilityLabel("Load progress")
        loadAllProgress.translatesAutoresizingMaskIntoConstraints = false
        loadAllProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true

        loadAllLabel.font = .systemFont(ofSize: 11)
        loadAllLabel.textColor = .secondaryLabelColor
        loadAllLabel.isHidden = true
        loadAllLabel.setAccessibilityIdentifier("results.loadAllProgressLabel")

        loadAllCancelButton.bezelStyle = .accessoryBarAction
        loadAllCancelButton.controlSize = .small
        loadAllCancelButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        loadAllCancelButton.target = self
        loadAllCancelButton.action = #selector(cancelLoadTapped)
        loadAllCancelButton.isHidden = true
        loadAllCancelButton.toolTip = "Stop the load. The rows already on screen stay."
        loadAllCancelButton.setAccessibilityIdentifier("results.cancelLoad")

        // Load More · Load All · spinner · bar · count · Cancel.
        for view in [loadMoreButton, loadAllButton, loadMoreSpinner, loadAllProgress, loadAllLabel, loadAllCancelButton] {
            loadControls.addArrangedSubview(view)
        }
        loadControls.orientation = .horizontal
        loadControls.alignment = .centerY
        loadControls.spacing = 6
        loadControls.setHuggingPriority(.defaultHigh, for: .horizontal)
        loadControls.setAccessibilityElement(true)
        loadControls.setAccessibilityRole(.group)
        loadControls.setAccessibilityLabel("Load rows")
        loadControls.setAccessibilityIdentifier("results.loadControls")
    }
}
