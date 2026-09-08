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

        // One centred row: Load More · Load All · spinner.
        let row = NSStackView(views: [loadMoreButton, loadAllButton, loadMoreSpinner])
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
