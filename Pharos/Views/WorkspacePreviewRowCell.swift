import AppKit

/// One row in the workspace-history preview pane: the result's colour dot, its
/// label, and its size caption — plus a mark when the row's SQL matched the
/// sidebar filter.
///
/// Lives outside `QueryHistoryVC` so `scripts/test-workspace-history-match.sh`
/// can compile it. `QueryHistoryVC` pulls in the whole PharosCore FFI bridge,
/// which cannot link in a plain swiftc binary.
class WorkspacePreviewRowCell: NSTableCellView {
    /// The tint of the match bar. A static so the harness can assert the bar is
    /// actually filled with it — a `CGColor` on a layer was unreachable from a
    /// test, and two ways of making the bar invisible passed the whole suite.
    static let matchTint: NSColor = .controlAccentColor

    /// Shown only when this row's SQL matched the active filter. An accent bar
    /// rather than a tinted row background: the background already carries
    /// alternating colours and selection, and an accent tint cannot be told
    /// apart from a selected row.
    ///
    /// An `NSBox` rather than a layer-backed view because AppKit resolves
    /// `fillColor` at draw time, so the bar follows a change to the system
    /// Accent colour. A `CGColor` in `layer.backgroundColor` never re-resolves.
    let matchBar = NSBox()
    let dot = NSView()
    let primaryLabel = NSTextField(labelWithString: "")
    let secondaryLabel = NSTextField(labelWithString: "")

    private static let primaryFontSize: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        matchBar.boxType = .custom
        matchBar.titlePosition = .noTitle
        matchBar.borderWidth = 0
        matchBar.fillColor = Self.matchTint
        matchBar.isHidden = true
        matchBar.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: Self.primaryFontSize)
        primaryLabel.textColor = .labelColor
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .right
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(matchBar)
        addSubview(dot)
        addSubview(primaryLabel)
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            matchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            matchBar.topAnchor.constraint(equalTo: topAnchor),
            matchBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            matchBar.widthAnchor.constraint(equalToConstant: 3),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            primaryLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: primaryLabel.trailingAnchor, constant: 8),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Set every visual state, every time. The table recycles these cells
    /// through `makeView`, so a branch that only *adds* the match mark would
    /// leave it on whichever row reuses this instance next.
    func configure(meta: WorkspaceResultMeta, dotColor: NSColor, isMatch: Bool) {
        dot.layer?.backgroundColor = dotColor.cgColor

        if let label = meta.customLabel, !label.isEmpty {
            primaryLabel.stringValue = label
        } else if let tableNames = meta.tableNames, !tableNames.isEmpty {
            primaryLabel.stringValue = tableNames
        } else {
            let firstLine = meta.sql.components(separatedBy: .newlines).first ?? meta.sql
            primaryLabel.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
        }

        var parts: [String] = []
        if let columnCount = meta.columnCount {
            parts.append("\(columnCount) col\(columnCount == 1 ? "" : "s")")
        }
        if let rowCount = meta.rowCount {
            parts.append("\(HistoryRowText.rowCountText(Int64(rowCount))) row\(rowCount == 1 ? "" : "s")")
        }
        secondaryLabel.stringValue = parts.joined(separator: " · ")
        secondaryLabel.textColor = meta.hasResults ? .secondaryLabelColor : .tertiaryLabelColor

        matchBar.isHidden = !isMatch
        primaryLabel.font = isMatch
            ? .systemFont(ofSize: Self.primaryFontSize, weight: .semibold)
            : .systemFont(ofSize: Self.primaryFontSize)

        // The bar and the semibold font are visual only. Clearing the label on
        // the unmatched path is required, not tidiness — the cell is recycled.
        setAccessibilityLabel(
            isMatch ? "\(primaryLabel.stringValue), matches the filter" : nil
        )
    }
}
