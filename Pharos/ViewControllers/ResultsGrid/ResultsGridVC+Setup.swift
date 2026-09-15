import AppKit

// MARK: - View Setup

extension ResultsGridVC {

    // MARK: - Load More Bar Setup

    func setupLoadMoreBar() {
        loadMoreBar.translatesAutoresizingMaskIntoConstraints = false
        loadMoreBar.isHidden = true

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreTapped)
        loadMoreButton.toolTip = "Fetch the next page. Each page is a new execution wrapped in LIMIT/OFFSET."

        loadAllButton.bezelStyle = .rounded
        loadAllButton.target = self
        loadAllButton.action = #selector(loadAllTapped)
        loadAllButton.toolTip = "Re-run the statement through a server cursor and replace the result with one consistent snapshot of every row."

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
        loadAllProgress.widthAnchor.constraint(equalToConstant: 140).isActive = true

        loadAllLabel.font = .systemFont(ofSize: 11)
        loadAllLabel.textColor = .secondaryLabelColor
        loadAllLabel.isHidden = true
        loadAllLabel.setAccessibilityIdentifier("results.loadAllProgressLabel")

        loadAllCancelButton.bezelStyle = .rounded
        loadAllCancelButton.controlSize = .small
        loadAllCancelButton.target = self
        loadAllCancelButton.action = #selector(cancelLoadTapped)
        loadAllCancelButton.isHidden = true
        loadAllCancelButton.toolTip = "Stop the load. The rows already on screen stay."
        loadAllCancelButton.setAccessibilityIdentifier("results.cancelLoad")

        // One centred row: Load More · Load All · spinner · bar · count · Cancel.
        let row = NSStackView(views: [
            loadMoreButton, loadAllButton, loadMoreSpinner,
            loadAllProgress, loadAllLabel, loadAllCancelButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        loadMoreBar.addSubview(row)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: loadMoreBar.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: loadMoreBar.centerYAnchor),
        ])
    }
}
