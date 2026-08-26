import AppKit

// MARK: - TagCaptureListView

/// The capture checklist: one row per result column, showing the VALUE the
/// selection holds there, with a box to tick.
///
/// ```
/// [✓]  Address   107.8.8.1
/// [ ]  Text      evil.example
/// [ ]  Number    3 values
/// ```
///
/// Values, not column names. When an analyst tags a row they are looking at,
/// `107.8.8.1` is the thing they are deciding about; the column name takes no
/// part in matching, so a checklist of names would be asking about something the
/// tag never records. The family beside it is what the captured condition will
/// be described by everywhere else in the app.
///
/// Holds no state of its own beyond the boxes. `TagManagerModel` owns which
/// columns are ticked, and this view reports a click and re-renders from the
/// model like every other view in this sheet.
final class TagCaptureListView: NSStackView {

    // MARK: - Row

    /// One column's row. Internal, like `TagRuleGridView.groups` and for the
    /// same reason: the suite reads the REAL controls rather than guessing which
    /// stack a view walk found.
    final class Row {
        let box: NSButton
        let familyLabel: NSTextField
        let valueLabel: NSTextField
        let container: NSStackView

        init(box: NSButton, familyLabel: NSTextField, valueLabel: NSTextField,
             container: NSStackView) {
            self.box = box
            self.familyLabel = familyLabel
            self.valueLabel = valueLabel
            self.container = container
        }
    }

    /// The rows, in RESULT COLUMN order. A row's position is its column index.
    private(set) var rows: [Row] = []

    /// A box was ticked or unticked: the column index, and its new state.
    var onToggle: ((Int, Bool) -> Void)?

    /// How wide the family column is held.
    ///
    /// Fixed rather than hugging, so every value starts at the same x and the
    /// list reads as a column instead of a ragged edge. Wide enough for
    /// "Date & time", which is the longest known label.
    private static let familyWidth: CGFloat = 84

    /// The narrowest a value may be squeezed to before it is allowed to
    /// truncate.
    ///
    /// A floor, not a width. Two views that hug at the same priority let the
    /// solver collapse one of them to nothing, which is a defect that renders as
    /// a blank row rather than as a layout error — this makes that impossible to
    /// reach silently.
    private static let minimumValueWidth: CGFloat = 60

    // MARK: Construction

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    private func build() {
        orientation = .vertical
        // `.leading` pins where a row STARTS; the per-row span pin below is what
        // makes each row the stack's own width. `.width` is silently discarded
        // by NSStackView — see NSStackView+SpanFullWidth.swift.
        alignment = .leading
        spacing = 4
    }

    // MARK: Rendering

    /// Rebuild from the capture and the ticks the model holds.
    ///
    /// nil draws NOTHING — not an empty list, no rows at all. Only `.add` has a
    /// selection to capture from; `.manage` and `.remove` are not choosing
    /// values and must not draw a checklist that implies they are.
    func render(_ capture: TagCapture?, checked: Set<Int>) {
        // `removeFromSuperview`, NOT `removeArrangedSubview`: the latter only
        // detaches a view from the ARRANGEMENT and leaves it in `subviews`,
        // where it would still draw.
        for row in rows { row.container.removeFromSuperview() }
        rows = []
        guard let capture else { return }

        for index in capture.columns.indices {
            let row = makeRow(capture, index: index, checked: checked.contains(index))
            addArrangedSubview(row.container)
            row.container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            rows.append(row)
        }
    }

    private func makeRow(_ capture: TagCapture, index: Int, checked: Bool) -> Row {
        let family = capture.familyText(forColumn: index)
        let value = capture.valueText(forColumn: index)

        // An empty title: the box selects a VALUE, and the value is drawn in its
        // own label so that it can truncate without taking the checkbox with it.
        // The column this box ticks is carried by `box.tag`, so no rendering of
        // the value can make the tick land on another column.
        let box = NSButton(checkboxWithTitle: "", target: self,
                           action: #selector(boxToggled(_:)))
        box.tag = index
        box.state = checked ? .on : .off
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Both already escaped: `familyText` through `TagFamilyLabel` and
        // `valueText` through `DisplayEscape`.
        box.setAccessibilityLabel("Capture \(family) \(value)")

        let familyLabel = NSTextField(labelWithString: family)
        familyLabel.font = .preferredFont(forTextStyle: .caption1)
        familyLabel.textColor = .secondaryLabelColor
        familyLabel.lineBreakMode = .byTruncatingTail
        familyLabel.widthAnchor.constraint(
            equalToConstant: Self.familyWidth).isActive = true

        // ESCAPED by `valueText`, because this is captured data — somebody
        // else's bytes drawn in a label this app owns.
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.textColor = .labelColor
        // The lowest hugging in the row, so the value takes the slack rather
        // than the family label doing it; and the lowest compression
        // resistance, so a long value TRUNCATES instead of pushing the row
        // wider than the list. The floor below is what stops the solver taking
        // that permission all the way to zero.
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumValueWidth).isActive = true

        let container = NSStackView(views: [box, familyLabel, valueLabel])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        return Row(box: box, familyLabel: familyLabel, valueLabel: valueLabel,
                   container: container)
    }

    // MARK: Events

    @objc private func boxToggled(_ sender: NSButton) {
        onToggle?(sender.tag, sender.state == .on)
    }
}
