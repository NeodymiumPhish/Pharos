import AppKit

/// The variables panel's list level: header, hairline, and a scrollable stack of
/// read-only rows. Owns no state — the panel VC hands it variables plus the set
/// of names the SQL references, and it reports interactions back by id.
final class VariableListView: NSView {

    var onAdd: (() -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Variables")
    private let countLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()

    /// Live rows, so `updateStates` can re-render in place instead of
    /// rebuilding the list (a rebuild would drop scroll position and hover).
    private var rows: [(id: UUID, view: VariableRowView)] = []

    init() {
        super.init(frame: .zero)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Content

    /// Rebuild every row. Call on variable add/delete/edit and on tab switch.
    func setVariables(_ variables: [QueryVariable], referenced: Set<String>) {
        countLabel.stringValue = variables.isEmpty ? "" : "\(variables.count)"
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        guard !variables.isEmpty else {
            let empty = NSTextField(labelWithString: "No variables — click + to add one.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            // Explicit, and pinned inside `padded` below rather than added to the
            // stack directly: in the old panel the stack centred this label instead
            // of stretching it, so the text sat inset from both edges and read as
            // centre-aligned. Keep both the alignment and the leading pin.
            empty.alignment = .left
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 2
            let padded = NSView()
            padded.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            padded.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 10),
                empty.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -10),
                empty.topAnchor.constraint(equalTo: padded.topAnchor, constant: 10),
                empty.bottomAnchor.constraint(equalTo: padded.bottomAnchor),
            ])
            rowsStack.addArrangedSubview(padded)
            // See the identical pin on each row below: `.width` alignment alone
            // does not reliably stretch every arranged subview to the stack's
            // width — measured directly, this wrapper (and the hairlines) can
            // end up a few points wide, flush to one edge, once *any* sibling
            // arranged subview also carries an explicit required width tie.
            padded.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return
        }

        // One list-level pass, because both rules depend on the whole list: a
        // duplicated name resolves last-definition-wins at render time, so which
        // row can fail — and which row is inert — depends on its neighbours.
        let states = VariableSubstitutor.rowStates(in: variables, referenced: referenced)

        for variable in variables {
            let row = VariableRowView(frame: .zero)
            row.configure(with: variable, state: states[variable.id])
            let id = variable.id
            row.onClick = { [weak self] in self?.onSelect?(id) }
            row.onDelete = { [weak self] in self?.onDelete?(id) }
            rowsStack.addArrangedSubview(row)
            // `.width` alignment on a vertical NSStackView does not reliably
            // stretch every arranged subview to the stack's width — measured
            // directly. In isolation a bare `NSView` (the hairline) does end up
            // full width from the weak alignment constraints alone, but a row
            // whose own required internal constraints already settle on a
            // narrower natural width does not, *and*, once any one arranged
            // subview in the stack carries an explicit required width tie like
            // this, the stack's weak per-view alignment constraints for its
            // *other* arranged subviews stop reliably resolving to full width
            // too. Pinning every arranged subview's width explicitly sidesteps
            // relying on that alignment mechanism at all.
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            let hairline = Self.hairline()
            rowsStack.addArrangedSubview(hairline)
            hairline.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            rows.append((id: id, view: row))
        }
    }

    /// Re-render only the state of existing rows. Called on the debounced
    /// editor-text scan, which must not disturb what the user is looking at.
    func updateStates(for variables: [QueryVariable], referenced: Set<String>) {
        let states = VariableSubstitutor.rowStates(in: variables, referenced: referenced)
        for (id, view) in rows {
            guard let variable = variables.first(where: { $0.id == id }) else { continue }
            view.configure(with: variable, state: states[id])
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add variable")
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.controlSize = .small
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "Add variable"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let headerSeparator = HairlineView()
        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false

        // `.fill` is not a valid NSStackView alignment; `.width` is the closest
        // named option, but (see the explicit width pins below) it does not by
        // itself reliably stretch arranged subviews to the stack's width.
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipView()
        scrollView.contentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(addButton)
        addSubview(headerSeparator)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            headerSeparator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rowsStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])
    }

    /// Row separator, inset from the leading edge like the app's inspector lists.
    private static func hairline() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = HairlineView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    @objc private func addTapped() { onAdd?() }
}

/// Flipped clip view so the rows stack grows top-down inside the scroll view.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A 1pt hairline that tracks light/dark via `updateLayer`, matching the
/// panel's existing `PanelBackgroundView` idiom (see `QueryVariablesPanelVC`).
///
/// Deliberately not `NSBox(boxType: .separator)`, which the plan originally
/// specified: measured directly, that box does not reliably honour an
/// explicit `heightAnchor.constraint(equalToConstant: 1)` once its container
/// is also width-constrained by a stack — Auto Layout resolves the
/// constraint graph as unambiguous at height 1, but the box's own internal
/// sizing then overrides that and renders ~5pt tall, overflowing 2pt above
/// and below its container (bleeding into neighbouring rows) — reproduced in
/// isolation with `boxType`, an explicit height constraint, and no other
/// competing constraints. A plain layer-backed view has no such internal
/// override and measures exactly as constrained.
private final class HairlineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
