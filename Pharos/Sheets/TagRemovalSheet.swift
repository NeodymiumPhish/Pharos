import AppKit

// MARK: - TagRemovalSheet

/// The removal confirmation sheet. Phase 4's "Remove From Tag" was a bare
/// menu action that deleted silently; this sheet fixes its three
/// understatements: it shows that the removal SPANS TAGS, that it is GLOBAL
/// (a tuple is the finding — deleting it stops that value matching in every
/// dataset, on every connection), and it lists exactly what is about to go.
///
/// The removal unit is the TUPLE, atomically. A multi-value tuple shows all
/// its values and a caption saying it goes as a whole: un-picking one value
/// would leave a tuple that matches MORE rows than before, and a remove
/// action that silently widens a tag is the worst outcome available.
///
/// Every tuple is rendered from `TagRemovalTuple.values`, one wrapping label
/// per value. There is deliberately no joined-string form of a tuple anywhere
/// in the model to render instead: any separator (" + ", say) is one a
/// captured display string can legally contain, so two structurally different
/// tuples could print the same joined line. A checkbox title would also be a
/// single truncating line, and a captured value can be kilobytes long and hold
/// newlines — a user must never be able to approve a deletion having seen only
/// its first line.
///
/// Cancel is the default button, by spec.
final class TagRemovalSheet: NSViewController {

    private let groups: [TagRemovalGroup]

    /// One entry per checkbox, in list order. The indices — not a copied
    /// tuple — so the live selection is read back as `[TagRemovalGroup]`, the
    /// shape `TagRemovalModel.footer(for:)` takes.
    private var entries: [(groupIndex: Int, tupleIndex: Int, box: NSButton)] = []

    private let scrollView = NSScrollView()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    private static let sheetWidth: CGFloat = 480
    private static let sheetHeight: CGFloat = 460

    /// Who the commit goes to. Injected with no default, deliberately: a
    /// default of `TagStore.shared` would name the store in THIS file, and the
    /// point of the seam is that the harness can compile the sheet without it.
    private let remover: TagTupleRemoving

    init(groups: [TagRemovalGroup], remover: TagTupleRemoving) {
        self.groups = groups
        self.remover = remover
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0,
                                       width: Self.sheetWidth, height: Self.sheetHeight))

        let title = NSTextField(labelWithString: "Remove From Tag")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let listStack = NSStackView()
        listStack.orientation = .vertical
        // `.leading` pins where a row STARTS; the span below is what makes it
        // span. See `NSStackView.spanArrangedSubviewsFullWidth` for why
        // `.width` cannot do either.
        listStack.alignment = .leading
        listStack.spacing = 4

        for (groupIndex, group) in groups.enumerated() {
            let dot = NSImageView(image: TagPalette.swatch(colorIndex: group.colorIndex))
            let name = NSTextField(labelWithString: group.tagName)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            // A tag name is free text and can be any length. Without a bound
            // on the label, `.byTruncatingTail` is a dead line: the label just
            // grows, `fittingSize` grows with it, and `presentAsSheet` sizes
            // the sheet from that — a 157-character name asked for 991pt. When
            // the parent window clamps it instead, the name overflows the clip
            // with NO ellipsis, and two long names differing only past the cut
            // read as the same tag. Same fix as TagManageSheet's list cell:
            // pin the trailing edge and let it truncate. The tooltip carries
            // the name in full.
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.toolTip = group.tagName
            let header = NSStackView(views: [dot, name])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 6
            listStack.addArrangedSubview(header)
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: header.trailingAnchor).isActive = true

            for (tupleIndex, tuple) in group.tuples.enumerated() {
                let box = NSButton(checkboxWithTitle: "", target: self,
                                   action: #selector(toggled))
                box.state = .on
                // The box carries no title, so it would be unlabelled to
                // VoiceOver. Spoken from exactly the text that is shown,
                // escaping included: a screen reader that announced the raw
                // value while the screen showed the escaped one would put the
                // two disclosures out of step.
                box.setAccessibilityLabel(
                    tuple.values.flatMap { value -> [String] in
                        // The disclosure is spoken too. A screen reader that
                        // read only the captured text would understate the
                        // deletion exactly as this sheet used to.
                        [TagRemovalModel.valueText(for: value).text]
                            + [TagRemovalModel.matchDisclosure(for: value)?.text].compactMap { $0 }
                    }.joined(separator: ", "))
                entries.append((groupIndex: groupIndex, tupleIndex: tupleIndex, box: box))

                var valueViews: [NSView] = tuple.values.flatMap { value -> [NSView] in
                    let rendered = TagRemovalModel.valueText(for: value)
                    let label = NSTextField(wrappingLabelWithString: rendered.text)
                    label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    // A placeholder is not captured data and must not read as
                    // if it were.
                    if rendered.isPlaceholder { label.textColor = .secondaryLabelColor }
                    // No `preferredMaxLayoutWidth` here, deliberately. The
                    // width comes from the constraint chain below — the list
                    // stack is pinned to the clip view and the scroll view to
                    // the form — so each label wraps at the width it is
                    // actually given, and follows it if the sheet ever
                    // resizes. A fixed bound was tried and measured: it only
                    // narrowed the wrap, and a bound WIDER than the label ends
                    // up makes AppKit reserve too little height and clip the
                    // last lines. `scripts/test-tag-removal-sheet.sh` measures
                    // both, on a spaced value and on an unbroken token.
                    guard let reach = TagRemovalModel.matchDisclosure(for: value) else {
                        return [label]
                    }
                    return [label, Self.reachLabel(reach)]
                }
                if tuple.values.count > 1 {
                    // The atomicity must be VISIBLE, not guessed at: this is
                    // what tells a single-value tuple apart from one that can
                    // only go whole.
                    let caption = NSTextField(
                        labelWithString: "Removed together — a tuple matches only as a whole.")
                    caption.font = .systemFont(ofSize: 10)
                    caption.textColor = .tertiaryLabelColor
                    valueViews.append(caption)
                }

                let valueStack = NSStackView(views: valueViews)
                valueStack.orientation = .vertical
                valueStack.alignment = .leading
                valueStack.spacing = 2

                let row = NSStackView(views: [box, valueStack])
                row.orientation = .horizontal
                // `.top`: a multi-line tuple must keep its checkbox beside the
                // FIRST value, not floating at the middle of the block.
                row.alignment = .top
                row.spacing = 6
                row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
                listStack.addArrangedSubview(row)
            }

            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.heightAnchor.constraint(equalToConstant: 6).isActive = true
            listStack.addArrangedSubview(gap)
        }
        listStack.spanArrangedSubviewsFullWidth()

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listStack

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor

        // Cancel is the DEFAULT (Return). The destructive button carries no
        // key equivalent at all: this sheet exists to slow the hand down.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\r"
        removeButton.target = self
        removeButton.action = #selector(removeChecked)
        removeButton.hasDestructiveAction = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancel, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let form = NSStackView(views: [title, scrollView, footerLabel, buttonRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        // The list's width is pinned to the form's HERE, along with the title,
        // the footer and the button row. It must not be left to depend on what
        // the list CONTAINS: the first version of this sheet gave its value
        // labels a fixed narrow wrap bound, and the scroll view collapsed with
        // them to 160pt inside a 440pt form, disclosing every value in a third
        // of the sheet. That bound is gone, so — measured, by removing this
        // line — the alignment above already holds these four rows at the
        // leading edge on its own today. This is here so that the full width
        // is a guarantee rather than a coincidence.
        form.spanArrangedSubviewsFullWidth()
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            // The sheet's width as a CONSTRAINT, not just a frame. A tag name
            // is free text with no length limit, and `presentAsSheet` sizes
            // from `fittingSize`: with only a frame, a 168-character name
            // asked for a 1248pt sheet. The label truncates against this.
            root.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 260),
            // Top/leading/trailing only: pinning the bottom too would cap the
            // list at the clip's height, and a list taller than the sheet is
            // the normal case here — it must scroll, not compress.
            listStack.topAnchor.constraint(equalTo: clip.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        view = root
        refresh()
    }

    /// The second line under a value: the form matching actually compares,
    /// shown only where it differs from the captured text.
    ///
    /// Indented by a PARAGRAPH STYLE rather than by nesting the label inside an
    /// inset container. The value labels carry no `preferredMaxLayoutWidth` and
    /// take their wrap bound from the constraint chain (see the value label
    /// above), which `scripts/test-tag-removal-sheet.sh` measures to the point;
    /// a head indent stays out of that chain entirely. It also carries the
    /// continuation lines of a long form, which a leading pad string would not.
    ///
    /// Smaller and dimmer than the value: this line is the app explaining, not
    /// captured data, and the reader must not have to work out which of the two
    /// came out of the database. A placeholder form goes dimmer still, the same
    /// rule the value label applies — the alarm in "matches as (empty)" is
    /// carried by the words, which is what gets read.
    private static func reachLabel(_ reach: TagMatchDisclosure.Line) -> NSTextField {
        let indent = NSMutableParagraphStyle()
        indent.firstLineHeadIndent = 14
        indent.headIndent = 14
        indent.lineBreakMode = .byWordWrapping
        let label = NSTextField(wrappingLabelWithString: reach.text)
        label.attributedStringValue = NSAttributedString(
            string: reach.text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: reach.isPlaceholder
                    ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: indent,
            ])
        return label
    }

    // MARK: State

    /// The checked tuples, back in the shape they arrived in. Rebuilt whole on
    /// every toggle rather than reduced over loose `(tagId, tupleId)` pairs, so
    /// the footer is computed from the very list the sheet is showing.
    ///
    /// A tag whose every tuple is unchecked contributes NO group — the same
    /// rule `TagRemovalModel.groups` applies, so the tag count can never count
    /// a heading that removes nothing. `keptByGroup` gains a key only when a
    /// box in that group is on, so the missing key is that rule.
    private var checkedGroups: [TagRemovalGroup] {
        var keptByGroup: [Int: Set<Int>] = [:]
        for entry in entries where entry.box.state == .on {
            keptByGroup[entry.groupIndex, default: []].insert(entry.tupleIndex)
        }
        return groups.enumerated().compactMap { index, group in
            guard let kept = keptByGroup[index] else { return nil }
            return TagRemovalGroup(
                tagId: group.tagId, tagName: group.tagName,
                colorIndex: group.colorIndex,
                tuples: group.tuples.enumerated()
                    .filter { kept.contains($0.offset) }
                    .map(\.element))
        }
    }

    /// The ids `removeChecked` commits, in the order the list shows them.
    ///
    /// Deliberately not private: the payload of a destructive action is the
    /// part that must be provable, and this lets it be read at intermediate
    /// states — after a toggle, before any commit — which clicking Remove
    /// cannot do without committing.
    var checkedTupleIds: [String] {
        TagRemovalModel.checkedTupleIds(in: checkedGroups)
    }

    @objc private func toggled() { refresh() }

    private func refresh() {
        let live = checkedGroups
        let count = live.reduce(0) { $0 + $1.tuples.count }
        // `footer(for:)`, not the raw counts overload: its numbers are derived
        // from the list above it and so cannot drift from it.
        //
        // Except at zero, where that sentence would read "Removes 0 tuples
        // from 0 tags. The values stop matching…" — the same non-sentence the
        // caller refuses to present an empty sheet for.
        footerLabel.stringValue = count == 0
            ? "Nothing selected. Nothing will be removed."
            : TagRemovalModel.footer(for: live)
        removeButton.isEnabled = count > 0
        removeButton.title = count == 1 ? "Remove 1 Tuple" : "Remove \(count) Tuples"
    }

    // MARK: Actions

    @objc private func cancelSheet() { dismiss(nil) }

    override func cancelOperation(_ sender: Any?) { dismiss(nil) }

    @objc private func removeChecked() {
        let ids = checkedTupleIds
        guard !ids.isEmpty else { return }
        do {
            try remover.removeTuples(ids: ids)
            dismiss(nil)
        } catch {
            NSLog("Tag value removal failed: \(error)")
            // Before building anything: with no window there is nothing to
            // hang the alert from, and the log above is the whole report.
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Could not remove the tuples"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }
}
