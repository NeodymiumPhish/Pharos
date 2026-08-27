import AppKit

/// The view-model one vertical result-tab row renders. Primitive fields only,
/// so this file compiles in a standalone swiftc test binary — `ResultTab`
/// itself drags in QueryResult and the rest of the model layer.
struct ResultTabRowModel: Equatable {
    let id: String
    let label: String
    let color: NSColor
    let countsText: String
    let isStale: Bool
}

/// Pure text formatting for the row's size caption. Kept out of the cell so the
/// strings are assertable without AppKit state.
enum ResultTabRowText {
    /// "46×240" — column count, then the grouped row count.
    static func countsText(columnCount: Int, rowCount: Int) -> String {
        "\(columnCount)×\(HistoryRowText.rowCountText(Int64(rowCount)))"
    }

    /// "2,500 rows" for statement results (INSERT/UPDATE/…).
    static func affectedText(rowsAffected: UInt64) -> String {
        let grouped = HistoryRowText.rowCountText(Int64(clamping: rowsAffected))
        return "\(grouped) row\(rowsAffected == 1 ? "" : "s")"
    }
}

/// One row of the vertical result-tabs panel: colour dot, label, size caption,
/// and a close button shown on hover or on the active row.
///
/// Lives outside `ResultTabsPanelVC` so `scripts/test-result-tab-row-cell.sh`
/// can compile it without the FFI bridge (the same split as
/// `WorkspacePreviewRowCell` / `QueryHistoryVC`).
class ResultTabRowCell: NSTableCellView {
    let dot = NSView()
    let primaryLabel = NSTextField(labelWithString: "")
    let secondaryLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()

    /// Close request for the row this cell currently shows.
    var onClose: ((String) -> Void)?

    private(set) var model: ResultTabRowModel?
    private var isActive = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: 12)
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

        let closeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close result")?
            .withSymbolConfiguration(closeConfig)
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true

        addSubview(dot)
        addSubview(primaryLabel)
        addSubview(secondaryLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            primaryLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: primaryLabel.trailingAnchor, constant: 8),
            secondaryLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Set every visual state, every time — the table recycles these cells
    /// through `makeView`, so a branch that only *adds* a state would leak it
    /// onto whichever row reuses this instance next.
    func configure(model: ResultTabRowModel, isActive: Bool) {
        self.model = model
        self.isActive = isActive

        // Escaped exactly once; display and accessibility both read the
        // escaped string so sizing, drawing, and VoiceOver cannot diverge.
        let escaped = DisplayEscape.escaped(model.label)
        primaryLabel.stringValue = escaped
        primaryLabel.textColor = model.isStale ? .tertiaryLabelColor : .labelColor

        let dotColor = model.isStale ? model.color.withAlphaComponent(0.4) : model.color
        dot.layer?.backgroundColor = dotColor.cgColor

        secondaryLabel.stringValue = model.countsText
        secondaryLabel.textColor = model.isStale ? .tertiaryLabelColor : .secondaryLabelColor

        // Recycled cells cannot remember hover: a stale `true` would leave a
        // close button on an unrelated row, inviting a click that closes the
        // wrong result. Re-derive it instead of resetting it blindly, so a
        // reload under a stationary pointer keeps the button the user can see.
        isHovered = isPointerInside
        updateCloseVisibility()

        var announced = escaped
        if model.isStale { announced += ", stale" }
        if !model.countsText.isEmpty { announced += ", \(model.countsText)" }
        setAccessibilityLabel(announced)
    }

    private func updateCloseVisibility() {
        closeButton.isHidden = !(isActive || isHovered)
    }

    /// Where the pointer actually is, asked directly rather than remembered.
    /// `mouseLocationOutsideOfEventStream` answers without needing an event,
    /// which is what a reload needs: no mouse moved, so no enter/exit will fire.
    ///
    /// The key-window test mirrors the tracking area's `.activeInKeyWindow`
    /// below, so the reload path and the live path agree on what "hovered"
    /// means. Without it, a query finishing while the user works in another app
    /// would reload these rows and derive hover from an incidental pointer
    /// position, showing a close button that live hover never would.
    ///
    /// Internal, not private, so a test can substitute a pointer position: a
    /// test cannot move the real pointer.
    var isPointerInside: Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    @objc private func closeTapped() {
        guard let model else { return }
        onClose?(model.id)
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverChanged(false)
    }

    /// Shared body for both `NSTrackingArea` callbacks above. Internal, not
    /// private: `NSEvent` has no public plain initialiser, so a standalone
    /// test cannot call `mouseEntered(with:)` itself and drives hover through
    /// this forwarder instead.
    func hoverChanged(_ inside: Bool) {
        isHovered = inside
        updateCloseVisibility()
    }
}
