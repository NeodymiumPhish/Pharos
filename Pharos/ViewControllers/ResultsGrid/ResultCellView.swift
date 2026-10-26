import AppKit

// MARK: - ResultCellView

// Moved out of ResultsDataSource.swift (2026-10-26) so a harness can compile
// the cell alone and render its dimmed marks offscreen
// (scripts/test-result-cell-marks.sh).

/// The cell's label, with one extra: an accessibility value the data source
/// can override — for a cell holding an uncommitted edit, or one drawing
/// dimmed marks.
///
/// A subclass is needed rather than a plain `setAccessibilityValue(_:)` call.
/// An `NSTextField`'s AXValue is served by its `NSTextFieldCell` and is always
/// the displayed string, so a value set on the view never reaches the
/// accessibility tree — reading it back through the AX API on a live grid is
/// what showed that, and it is the only way to tell.
final class ResultCellLabel: NSTextField {
    /// Replaces the AXValue while set. nil restores the displayed text.
    var accessibilityValueOverride: String? {
        didSet {
            // Assigned on every realize now, nil to nil for most cells: post
            // only a real change, or every scroll tick floods the AX server.
            guard oldValue != accessibilityValueOverride else { return }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    // No `override`: AppKit declares `accessibilityValue()` on NSObject
    // through the NSAccessibility protocol, not as a method of NSTextField, so
    // Swift sees nothing to override. Declaring it here still replaces the
    // Objective-C implementation for this class, which is what the
    // accessibility server asks.
    @objc func accessibilityValue() -> Any? {
        accessibilityValueOverride ?? stringValue
    }
}

/// Internal, not private: `ResultsGridVC+Editing` has to reach the cell's
/// editor field to give it the keyboard once the table has realized the view.
final class ResultCellView: NSTableCellView {
    /// Type-appropriate unselected text color (purple for temporal, tertiary
    /// for NULL, blue for numeric, etc.). Setter keeps `textField.textColor` in
    /// sync when not selected — callers no longer assign textField directly.
    var normalTextColor: NSColor = .labelColor {
        didSet { updateTextColor() }
    }

    // MARK: - Pending-edit marker

    /// Width of the accent rule down the leading edge of a cell holding an
    /// uncommitted edit. 2pt: visible beside the 6pt text inset without
    /// touching the glyphs.
    static let pendingRuleWidth: CGFloat = 2

    private var pendingRuleLayer: CALayer?

    /// Whether this cell carries an uncommitted edit. Assigned on EVERY
    /// realize, including false, so a recycled cell cannot keep another row's
    /// marker — the same rule the find border and the tag tint follow.
    var showsPendingRule: Bool = false {
        didSet {
            guard oldValue != showsPendingRule else { return }
            updatePendingRule()
        }
    }

    private func updatePendingRule() {
        if showsPendingRule {
            let rule = pendingRuleLayer ?? {
                let fresh = CALayer()
                // No implicit animation: the rule appears the instant the edit
                // commits, and a fade would read as the grid still thinking.
                fresh.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                layer?.addSublayer(fresh)
                pendingRuleLayer = fresh
                return fresh
            }()
            rule.backgroundColor = NSColor.controlAccentColor.cgColor
            rule.isHidden = false
            layoutPendingRule()
        } else {
            pendingRuleLayer?.isHidden = true
        }
    }

    private func layoutPendingRule() {
        guard let rule = pendingRuleLayer, !rule.isHidden else { return }
        rule.frame = NSRect(x: 0, y: 0, width: Self.pendingRuleWidth, height: bounds.height)
    }

    // MARK: - Inline editor

    /// The real editable field, made only for the cell being edited and kept
    /// afterwards (cells are recycled, and rebuilding a field per edit would
    /// churn the field editor). Hidden whenever `endEditing()` has run.
    private(set) var editorField: NSTextField?

    /// Swap the label for an editable field seeded with `text`.
    func beginEditing(text: String, font: NSFont, delegate: NSTextFieldDelegate?) {
        let field = editorField ?? {
            let fresh = NSTextField(string: "")
            fresh.isBordered = true
            fresh.bezelStyle = .squareBezel
            fresh.isEditable = true
            fresh.isSelectable = true
            fresh.drawsBackground = true
            fresh.usesSingleLineMode = true
            fresh.lineBreakMode = .byClipping
            fresh.cell?.wraps = false
            fresh.cell?.isScrollable = true
            fresh.focusRingType = .default
            fresh.translatesAutoresizingMaskIntoConstraints = false
            addSubview(fresh)
            NSLayoutConstraint.activate([
                fresh.leadingAnchor.constraint(equalTo: leadingAnchor),
                fresh.trailingAnchor.constraint(equalTo: trailingAnchor),
                fresh.topAnchor.constraint(equalTo: topAnchor),
                fresh.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            editorField = fresh
            return fresh
        }()
        // The same face as the cell, so the text does not jump on the way in.
        field.font = font
        field.textColor = .labelColor
        field.delegate = delegate
        field.stringValue = text
        field.isHidden = false
        field.setAccessibilityIdentifier("results.cellEditor")
        textField?.isHidden = true
    }

    /// Put the label back. Safe to call on a cell that was never edited.
    func endEditing() {
        guard let field = editorField, !field.isHidden else { return }
        field.isHidden = true
        field.delegate = nil
        textField?.isHidden = false
    }

    /// True while this cell is showing its editor.
    var isEditing: Bool { editorField.map { !$0.isHidden } ?? false }

    override func layout() {
        super.layout()
        layoutPendingRule()
    }

    /// True when this cell is part of the active cell-mode selection. Setter
    /// flips text color between white (selected) and `normalTextColor`. The
    /// background fill is managed externally by the data source so it can
    /// coordinate precedence with find-match highlighting.
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateTextColor()
        }
    }

    /// True while the grid's window is key. A selected cell in a non-key
    /// window paints the system's unemphasized (grey) selection, and its
    /// text must stay readable on that grey, so the text colour follows.
    var selectionEmphasized: Bool = true {
        didSet {
            guard oldValue != selectionEmphasized else { return }
            updateTextColor()
        }
    }

    private func updateTextColor() {
        // Row-emphasis (.emphasized) wins when NSTableView sets it via
        // selectRowIndexes (row-number-column selection). Cell-mode selection
        // never sets .emphasized, so isSelected drives the color.
        let color: NSColor
        let markColor: NSColor
        if backgroundStyle == .emphasized {
            color = .alternateSelectedControlTextColor
            markColor = color.withAlphaComponent(Self.selectedMarkAlpha)
        } else if isSelected {
            // The system's own pair for selected content: white on the accent
            // fill, label-ish grey on the unemphasized fill. `.white` was hard
            // coded here, and stayed white on the grey fill of a non-key window.
            color = selectionEmphasized
                ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor
            markColor = color.withAlphaComponent(Self.selectedMarkAlpha)
        } else {
            color = normalTextColor
            markColor = .tertiaryLabelColor
        }
        textField?.textColor = color
        if !dimmedRanges.isEmpty { applyMarks(textColor: color, markColor: markColor) }
    }

    // MARK: - Displayed text

    /// How strongly a mark draws on a selection fill, where tertiary grey
    /// would vanish: the selected text colour, faded. Measured offscreen on an
    /// emphasized cell: 0.55 drew the dot at 0.78 of the text's ink, too close
    /// to read as a mark; 0.4 draws it at 0.63.
    static let selectedMarkAlpha: CGFloat = 0.4

    /// The tier B marks of the text on show, as UTF-16 ranges. On the VIEW: an
    /// `NSCell` subclass must carry no Swift stored properties.
    private(set) var dimmedRanges: [NSRange] = []

    /// Show `text`, drawing `dimmedRanges` of it as dimmed marks. EVERY write
    /// of the label's text goes through here — a recycled cell that kept its
    /// last value's ranges would recolour the wrong characters of the next.
    /// Set the label's font and alignment first: the marked form copies them.
    func setDisplayedText(_ text: String, dimmedRanges: [NSRange] = []) {
        self.dimmedRanges = dimmedRanges
        textField?.stringValue = text
        if !dimmedRanges.isEmpty { updateTextColor() }
    }

    /// Rebuild the label as an attributed string: the text colour throughout,
    /// the mark colour on the marks. The paragraph style carries the label's
    /// own alignment and tail truncation, which an attributed value would
    /// otherwise replace with its defaults.
    private func applyMarks(textColor: NSColor, markColor: NSColor) {
        guard let field = textField else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = field.alignment
        paragraph.lineBreakMode = field.lineBreakMode
        let marked = NSMutableAttributedString(string: field.stringValue, attributes: [
            .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
        for range in dimmedRanges where NSMaxRange(range) <= marked.length {
            marked.addAttribute(.foregroundColor, value: markColor, range: range)
        }
        field.attributedStringValue = marked
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }
}
