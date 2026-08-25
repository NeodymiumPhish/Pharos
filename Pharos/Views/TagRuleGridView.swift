import AppKit

// MARK: - TagRuleGridView

/// The rules of one tag, each a bordered group of condition rows.
///
/// Holds no state of its own: it renders an `EditableTag` and reports what the
/// analyst did. `TagManagerModel` is the only thing that decides whether an edit
/// is allowed, and this view never second-guesses it.
final class TagRuleGridView: NSStackView {

    struct Callbacks {
        var addRule: () -> Void
        var removeRule: (Int) -> Void
        var addCondition: (Int) -> Void
        var removeCondition: (Int, Int) -> Void
        var changedCondition: (Int, Int, TagCondition) -> Void
        var invalidCondition: (Int, Int, TagConditionEditor.Invalid?) -> Void
    }

    /// The rule groups, in MODEL order.
    ///
    /// Internal, like `TagConditionRowView`'s controls and for the same reason:
    /// the suite reaches a rule's rows through this rather than guessing which
    /// stack a view walk had found, and a walk cannot tell a group apart from
    /// the caption above it anyway.
    private(set) var groups: [TagRuleGroupView] = []

    /// What a rule MEANS, said once above the groups.
    ///
    /// Conditions inside a rule are ANDed and the rules themselves are ORed,
    /// which is not something the layout can show. It is also why an index here
    /// is never the same number as a view position: group N is at arranged
    /// position N+1, under this caption.
    let semanticsLabel = NSTextField(labelWithString:
        "A row carries this tag when it satisfies every condition of any one rule.")
    let addRuleButton = NSButton()

    /// Where the add-rule control sits. A full-width row holding a button that
    /// hugs its own text, so `spanArrangedSubviewsFullWidth()` can pin EVERY
    /// arranged subview without stretching the button across the grid.
    private let footerRow = NSStackView()
    private var callbacks: Callbacks?

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
        semanticsLabel.font = .preferredFont(forTextStyle: .caption1)
        semanticsLabel.textColor = .secondaryLabelColor
        semanticsLabel.lineBreakMode = .byWordWrapping
        semanticsLabel.maximumNumberOfLines = 0
        semanticsLabel.cell?.wraps = true

        addRuleButton.title = "Add Rule"
        addRuleButton.bezelStyle = .rounded
        addRuleButton.setButtonType(.momentaryPushIn)
        addRuleButton.target = self
        addRuleButton.action = #selector(addRuleTapped)
        addRuleButton.setAccessibilityLabel("Add a rule to this tag")
        addRuleButton.setContentHuggingPriority(.required, for: .horizontal)

        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 6
        footerRow.addArrangedSubview(addRuleButton)
        footerRow.addArrangedSubview(TagRuleGridView.slack())

        orientation = .vertical
        // `.leading` pins where a row STARTS; the span pin is what makes each
        // row the stack's own width. `.width` is silently discarded by
        // NSStackView — see NSStackView+SpanFullWidth.swift.
        alignment = .leading
        spacing = 10
        addArrangedSubview(semanticsLabel)
        addArrangedSubview(footerRow)
        // Reaches the two subviews that exist NOW. A group added later is
        // pinned by `render` as it goes, because this helper constrains what is
        // there when it runs.
        spanArrangedSubviewsFullWidth()
    }

    // MARK: Rendering

    /// Rebuild from scratch. The caller re-renders after every model change
    /// rather than patching, because the model is the truth and a diffing view
    /// is a second place for the two to disagree.
    func render(_ tag: EditableTag, callbacks: Callbacks) {
        self.callbacks = callbacks
        // `removeFromSuperview`, NOT `removeArrangedSubview`. The latter only
        // detaches a view from the ARRANGEMENT and leaves it in `subviews`,
        // where it would still draw and would still shift every later view's
        // position.
        for group in groups { group.removeFromSuperview() }
        groups = []

        for (ruleIndex, rule) in tag.rules.enumerated() {
            // `ruleIndex` is captured HERE, from the model, and never re-derived
            // from the view tree. It is the number `TagManagerModel` indexes
            // with, and the view's own position is not the same number.
            let group = TagRuleGroupView(rule: rule, ordinal: ruleIndex + 1,
                                         callbacks: callbacks, ruleIndex: ruleIndex)
            groups.append(group)
            // Before the footer, which is always last.
            insertArrangedSubview(group, at: max(arrangedSubviews.count - 1, 0))
            group.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    // MARK: Actions

    @objc private func addRuleTapped(_ sender: Any?) {
        callbacks?.addRule()
    }

    // MARK: Helpers

    /// A view that takes whatever width is left over, so the control beside it
    /// keeps its natural size and sits at the leading edge.
    ///
    /// A plain `NSView` has no intrinsic size, so it needs a height or the
    /// horizontal stack's `.centerY` alignment leaves it ambiguous.
    static func slack() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                     for: .horizontal)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
}

// MARK: - TagRuleGroupView

/// One rule, inside a border: a heading, its conditions, and the two controls
/// that change it.
///
/// The border is what makes "these conditions are ANDed together, and these
/// other ones are a different rule" readable at a glance. Without it a flat list
/// of rows reads as one long AND, which is the opposite of what it means.
final class TagRuleGroupView: NSView {

    /// The rule's index in the MODEL, fixed at render. Never re-derived from
    /// the view tree: the grid draws a caption above the groups, so this number
    /// and the view's own position differ by one, and a delete reported by
    /// position would remove the wrong rule.
    let ruleIndex: Int
    /// May this rule's conditions be changed? Straight from
    /// `EditableRule.isEditable` — this view never decides it.
    let isEditableRule: Bool

    let titleLabel: NSTextField
    let deleteRuleButton = NSButton()
    let addConditionButton = NSButton()
    /// Why the rows are greyed. Hidden for a rule this build understands.
    let unsupportedNotice = NSTextField(labelWithString: TagRuleGroupView.unsupportedText)
    private(set) var conditionRows: [TagConditionRowView] = []

    /// What a greyed rule says for itself.
    ///
    /// It must not read as a fault. The rule MATCHES perfectly well — the
    /// matcher skips only conditions it cannot evaluate — and it is this build
    /// that is behind, not the data.
    static let unsupportedText =
        "A newer version of Pharos wrote this rule. It still matches rows; "
        + "this version can delete it, but cannot change it."

    private let border = NSBox()
    private let stack = NSStackView()
    private let callbacks: TagRuleGridView.Callbacks

    // MARK: Construction

    init(rule: EditableRule, ordinal: Int,
         callbacks: TagRuleGridView.Callbacks, ruleIndex: Int) {
        self.ruleIndex = ruleIndex
        self.isEditableRule = rule.isEditable
        self.callbacks = callbacks
        self.titleLabel = NSTextField(labelWithString: "Rule \(ordinal)")
        super.init(frame: .zero)

        buildBorder()
        buildControls()
        buildRows(rule, ruleIndex: ruleIndex, callbacks: callbacks)
        buildLayout()
        setEditable(rule.isEditable)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: an empty `NSBox` behind the content, pinned to this
    /// view's edges. Its `contentView` is deliberately left alone — an `NSBox`
    /// laying out its own content view is one more thing between the rows and
    /// the measurements that check them.
    private func buildBorder() {
        border.boxType = .custom
        border.titlePosition = .noTitle
        border.borderWidth = 1
        border.cornerRadius = 6
        border.borderColor = .separatorColor
        border.fillColor = .clear
        border.contentViewMargins = .zero
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func buildControls() {
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        // The title takes the slack so the delete button lands at the trailing
        // edge without a spacer of its own.
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        deleteRuleButton.image = NSImage(systemSymbolName: "trash",
                                         accessibilityDescription: "Delete this rule")
        deleteRuleButton.bezelStyle = .accessoryBarAction
        deleteRuleButton.isBordered = false
        deleteRuleButton.target = self
        deleteRuleButton.action = #selector(deleteRuleTapped)
        deleteRuleButton.setAccessibilityLabel("Delete this rule")
        deleteRuleButton.setContentHuggingPriority(.required, for: .horizontal)

        addConditionButton.title = "Add Condition"
        addConditionButton.bezelStyle = .rounded
        addConditionButton.setButtonType(.momentaryPushIn)
        addConditionButton.target = self
        addConditionButton.action = #selector(addConditionTapped)
        addConditionButton.setAccessibilityLabel("Add a condition to this rule")
        addConditionButton.setContentHuggingPriority(.required, for: .horizontal)

        unsupportedNotice.font = .preferredFont(forTextStyle: .caption1)
        unsupportedNotice.textColor = .secondaryLabelColor
        unsupportedNotice.lineBreakMode = .byWordWrapping
        unsupportedNotice.maximumNumberOfLines = 0
        unsupportedNotice.cell?.wraps = true
    }

    /// `ruleIndex` arrives as a parameter, not read off `self`, so each row's
    /// closures close over two plain `Int`s and hold no reference to the view.
    /// A closure that reached back into the view tree for its index is exactly
    /// the mistake this shape prevents.
    private func buildRows(_ rule: EditableRule, ruleIndex: Int,
                           callbacks: TagRuleGridView.Callbacks) {
        for (conditionIndex, condition) in rule.conditions.enumerated() {
            // Both indices are captured from the MODEL, at render, and travel
            // with the row's own callbacks. Nothing downstream has to work out
            // where the row ended up.
            let row = TagConditionRowView(
                condition: condition,
                isEditable: rule.isEditable,
                callbacks: TagConditionRowView.Callbacks(
                    changed: { callbacks.changedCondition(ruleIndex, conditionIndex, $0) },
                    invalid: { callbacks.invalidCondition(ruleIndex, conditionIndex, $0) },
                    removed: { callbacks.removeCondition(ruleIndex, conditionIndex) }))
            conditionRows.append(row)
        }
    }

    private func buildLayout() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(deleteRuleButton)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.addArrangedSubview(addConditionButton)
        footer.addArrangedSubview(TagRuleGridView.slack())

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(header)
        // Above the rows, not below them. A reader who meets the greyed
        // controls first has to work out what is wrong before being told.
        stack.addArrangedSubview(unsupportedNotice)
        for row in conditionRows { stack.addArrangedSubview(row) }
        stack.addArrangedSubview(footer)
        stack.spanArrangedSubviewsFullWidth()

        stack.translatesAutoresizingMaskIntoConstraints = false
        // Added AFTER the border, so the content draws on top of it.
        addSubview(stack)
        let inset: CGFloat = 10
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    // MARK: Enablement

    /// Greys what cannot be changed, and NOTHING else.
    ///
    /// Per rule, never per grid: a tag holding one rule from a newer build must
    /// leave every other rule of that tag fully editable.
    ///
    /// The DELETE button is the deliberate exception. Deleting a rule by id
    /// needs no understanding of its conditions, and an analyst who cannot edit
    /// a rule must still be able to get rid of it — a rule that could be
    /// neither changed nor removed would be stuck in the tag for ever.
    ///
    /// Adding a condition stays disabled: `TagManagerModel.addCondition`
    /// refuses it anyway, and a live control that does nothing is worse than a
    /// dead one.
    private func setEditable(_ isEditable: Bool) {
        addConditionButton.isEnabled = isEditable
        deleteRuleButton.isEnabled = true
        titleLabel.textColor = isEditable ? .labelColor : .secondaryLabelColor
        // NSStackView detaches a hidden arranged subview, so the notice takes no
        // space at all on a rule that needs no explaining.
        unsupportedNotice.isHidden = isEditable
        // The rows grey THEMSELVES — `TagConditionRowView` was given
        // `isEditable` at construction. Reaching in here to disable them again
        // would be a second opinion on a decision the model already made.
    }

    // MARK: Actions

    @objc private func deleteRuleTapped(_ sender: Any?) {
        callbacks.removeRule(ruleIndex)
    }

    @objc private func addConditionTapped(_ sender: Any?) {
        callbacks.addCondition(ruleIndex)
    }
}
